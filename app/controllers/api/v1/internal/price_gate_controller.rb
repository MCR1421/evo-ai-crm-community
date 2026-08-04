class Api::V1::Internal::PriceGateController < ActionController::API
  before_action :verify_internal_secret

  def check
    phone = params.require(:phone).delete('+')
    gate = PriceGateService.new(phone)

    if params[:quote].present? && !gate.released?
      gate.register_pending(
        conversation_id: params[:conversation_id],
        agent_bot_id: params[:agent_bot_id],
        quote: params[:quote].to_unsafe_h
      )
    end

    if gate.released?
      render json: { released: true, quote: gate.pending_quote }, status: :ok
    else
      render json: { released: false }, status: :ok
    end
  end

  def release
    # Triggered either directly (phone param) or via the Automation Rule's
    # generic send_webhook_event action, which POSTs Conversation#webhook_data
    # (meta.sender.phone_number) with no way to pass a custom param — see
    # docs/superpowers/plans/2026-07-31-vascaino-evoai-core-migration.md Task 10.
    phone = params[:phone].presence || params.dig(:meta, :sender, :phone_number)
    return render json: { error: 'phone is required' }, status: :bad_request if phone.blank?

    gate = PriceGateService.new(phone.delete('+'))

    unless gate.pending_conversation_id
      return render json: { error: 'No pending price gate for this phone number' }, status: :not_found
    end

    gate.release!
    conversation_id = gate.pending_conversation_id
    trigger_resume(gate)
    SellerEscalationExecution.reset_for_conversation(conversation_id)
    gate.clear!

    render json: { released: true }, status: :ok
  end

  # GET-friendly variant of #release, meant to be clicked directly from a
  # link inside the private note the price-gate guardrail posts (see
  # evo-ai-processor-community/src/services/adk/runners/standard_runner.py).
  # A plain <a href> click is always a GET, so #release (POST-only, used by
  # the "Liberar Preço" macro's Automation Rule webhook) can't be reused as
  # the link target directly - same auth (X-Internal-Secret header or
  # ?internal_secret= query param) applies via verify_internal_secret.
  def release_from_link
    phone = params[:phone].presence
    return render_release_link_result(false, 'Telefone não informado no link.') if phone.blank?

    gate = PriceGateService.new(phone.delete('+'))

    unless gate.pending_conversation_id
      return render_release_link_result(
        false,
        'Não há cotação pendente para esse cliente — já foi liberada antes ou expirou.'
      )
    end

    gate.release!
    conversation_id = gate.pending_conversation_id
    trigger_resume(gate)
    SellerEscalationExecution.reset_for_conversation(conversation_id)
    gate.clear!

    render_release_link_result(true, 'O cliente vai receber a mensagem com o preço em instantes.')
  end

  private

  def render_release_link_result(success, message)
    icon = success ? '✅' : '⚠️'
    title = success ? 'Preço liberado!' : 'Não foi possível liberar'
    accent = success ? '#22c55e' : '#f59e0b'
    html = <<~HTML
      <!doctype html>
      <html lang="pt-BR">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{title}</title>
          <style>
            body{font-family:-apple-system,system-ui,Segoe UI,Roboto,sans-serif;background:#0f172a;
              color:#e2e8f0;display:flex;align-items:center;justify-content:center;min-height:100vh;
              margin:0;padding:24px;text-align:center}
            .card{background:#1e293b;padding:32px 28px;border-radius:16px;max-width:380px;
              box-shadow:0 10px 30px rgba(0,0,0,.3)}
            .icon{font-size:44px;margin-bottom:12px}
            h1{font-size:19px;margin:0 0 10px;color:#{accent}}
            p{color:#94a3b8;font-size:14px;line-height:1.5;margin:0}
          </style>
        </head>
        <body>
          <div class="card">
            <div class="icon">#{icon}</div>
            <h1>#{title}</h1>
            <p>#{ERB::Util.html_escape(message)}</p>
          </div>
        </body>
      </html>
    HTML
    render html: html.html_safe, layout: false
  end

  def trigger_resume(gate)
    conversation = Conversation.find_by(id: gate.pending_conversation_id)
    return unless conversation

    agent_bot = AgentBot.find_by(id: gate.pending_agent_bot_id)
    return unless agent_bot

    message = Message.new(
      content: '[gate_liberado]',
      conversation: conversation,
      inbox: conversation.inbox,
      message_type: :incoming
    )

    BotRuntime::DelegationService.new(agent_bot, message, conversation).delegate
  rescue StandardError => e
    Rails.logger.error "[PriceGateController] Failed to trigger resume: #{e.message}"
  end

  def verify_internal_secret
    # Header for direct calls (the Custom Tool, price_gate#check); query param
    # for the Automation Rule's send_webhook_event, which is a generic
    # WebhookJob POST that can't attach custom headers (see Task 10 in the
    # migration plan) — so the release URL embeds ?internal_secret=... instead.
    provided = request.headers['X-Internal-Secret'].presence || params[:internal_secret]
    expected = ENV.fetch('INTERNAL_TOOLS_SECRET')

    return if ActiveSupport::SecurityUtils.secure_compare(provided.to_s, expected)

    render json: { error: 'Unauthorized' }, status: :unauthorized
  end
end
