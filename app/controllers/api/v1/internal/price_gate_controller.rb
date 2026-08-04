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

  # GET: shows the pending quote as an editable form (product selection,
  # price, discount). Deliberately has NO side effects - state only
  # changes on the POST below. A bare GET being safe to hit repeatedly
  # (e.g. from a link-preview bot) is a real fix over the old
  # release_from_link, which released the gate on GET.
  def release_form
    phone = params[:phone].presence
    return render_release_link_result(false, 'Telefone não informado no link.') if phone.blank?

    gate = PriceGateService.new(phone.delete('+'))
    quote = gate.pending_quote
    produtos = quote.is_a?(Hash) ? quote['produtos'] : nil

    if produtos.blank?
      return render_release_link_result(
        false,
        'Não há cotação pendente para esse cliente — já foi liberada antes ou expirou.'
      )
    end

    render html: release_form_html(produtos, phone).html_safe, layout: false
  end

  # POST: seller confirms which products/prices to send. Builds the final
  # message from exactly what was submitted and posts it straight to the
  # conversation - the bot/LLM never composes or sees this message, so
  # what the seller saw on the form is exactly what the customer gets.
  def submit_release_form
    phone = params[:phone].presence
    return render_release_link_result(false, 'Telefone não informado no link.') if phone.blank?

    gate = PriceGateService.new(phone.delete('+'))
    quote = gate.pending_quote
    produtos = quote.is_a?(Hash) ? quote['produtos'] : nil

    if produtos.blank?
      return render_release_link_result(
        false,
        'Não há cotação pendente para esse cliente — já foi liberada antes ou expirou.'
      )
    end

    products_params = params[:products].presence.try(:to_unsafe_h) || {}
    selected_params = products_params.values.select { |p| p['selected'] == '1' }

    error = nil
    items = selected_params.map do |p|
      price = parse_price(p['preco_venda'])
      error ||= "Preço inválido para #{p['nome']}." if price.nil? || price <= 0
      { nome: p['nome'], codigo: p['codigo'], preco: price }
    end

    if error
      merged = merge_submitted_products(produtos, products_params)
      return render html: release_form_html(merged, phone, error: error).html_safe, layout: false
    end

    conversation = Conversation.find_by(id: gate.pending_conversation_id)
    agent_bot = AgentBot.find_by(id: gate.pending_agent_bot_id)

    if items.any?
      unless conversation && agent_bot
        return render_release_link_result(
          false, 'Conversa ou bot não encontrado — a cotação pode ter expirado.'
        )
      end
      AgentBots::MessageCreator.new(agent_bot).create_bot_reply(
        build_price_message(items), conversation, force: true
      )
    end

    gate.release!
    SellerEscalationExecution.reset_for_conversation(gate.pending_conversation_id)
    gate.clear!

    render_release_link_result(
      true,
      items.any? ? 'Mensagem enviada ao cliente com os valores selecionados.' : 'Nenhum produto selecionado — nada foi enviado.'
    )
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

  def format_brl(value)
    ActiveSupport::NumberHelper.number_to_currency(value, unit: 'R$ ', separator: ',', delimiter: '.')
  end

  PRICE_BR_PATTERN = /\A\d+(\.\d{3})*,\d{1,2}\z/
  PRICE_PLAIN_PATTERN = /\A\d+(\.\d{1,2})?\z/

  # Only accepts two well-defined formats - a plain decimal (what the
  # HTML number input sends) or a pt-BR grouped decimal (e.g. "1.234,56")
  # - and rejects everything else, including strings with a numeric
  # prefix followed by garbage (String#to_f would silently truncate
  # those, e.g. "12abc".to_f == 12.0).
  def parse_price(raw)
    return nil if raw.blank?

    normalized = raw.to_s.strip
    case normalized
    when PRICE_BR_PATTERN
      normalized = normalized.delete('.').tr(',', '.')
    when PRICE_PLAIN_PATTERN
      # already a plain decimal (e.g. from the HTML number input) - use as-is
    else
      return nil
    end

    Float(normalized)
  rescue ArgumentError, TypeError
    nil
  end

  def build_price_message(items)
    lines = items.map { |i| "- #{i[:nome]} (cód. #{i[:codigo]}): #{format_brl(i[:preco])}" }
    "Segue os valores:\n#{lines.join("\n")}\n\nQualquer dúvida, fico à disposição!"
  end

  def merge_submitted_products(produtos, products_params)
    by_codigo = products_params.values.index_by { |p| p['codigo'] }
    produtos.map do |produto|
      submitted = by_codigo[produto['codigo']]
      next produto unless submitted

      produto.merge(
        'preco_venda' => parse_price(submitted['preco_venda']) || produto['preco_venda'],
        'selected' => submitted['selected'] == '1'
      )
    end
  end

  def release_form_html(produtos, phone, error: nil)
    secret = ENV.fetch('INTERNAL_TOOLS_SECRET')
    rows = produtos.each_with_index.map do |produto, index|
      codigo = produto['codigo'].to_s
      nome = produto['nome'].to_s
      preco = produto['preco_venda']
      custo = produto['preco_custo']
      selected = produto.key?('selected') ? produto['selected'] : true
      preco_str = preco.is_a?(Numeric) ? format('%.2f', preco) : ''
      custo_html = custo.is_a?(Numeric) ? format_brl(custo) : '-'
      estoque_html = produto['em_estoque'] ? '✅ Em estoque' : '⚠️ Sem estoque'

      <<~ROW
        <div class="product-row" data-tabela="#{preco_str}">
          <label class="checkbox">
            <input type="checkbox" name="products[#{index}][selected]" value="1" #{selected ? 'checked' : ''}>
            <strong>#{ERB::Util.html_escape(nome)}</strong> (cód. #{ERB::Util.html_escape(codigo)})
          </label>
          <input type="hidden" name="products[#{index}][codigo]" value="#{ERB::Util.html_escape(codigo)}">
          <input type="hidden" name="products[#{index}][nome]" value="#{ERB::Util.html_escape(nome)}">
          <div class="row-fields">
            <label>Preço final (R$)
              <input type="number" step="0.01" min="0" class="preco-final" name="products[#{index}][preco_venda]" value="#{preco_str}">
            </label>
            <label>Desconto (%)
              <input type="number" step="0.01" class="desconto-percent" value="0">
            </label>
            <label>Desconto (R$)
              <input type="number" step="0.01" class="desconto-valor" value="0">
            </label>
            <span class="custo">Custo: #{custo_html}</span>
            <span class="estoque">#{estoque_html}</span>
          </div>
        </div>
      ROW
    end.join

    error_html = error ? "<p class=\"error\">⚠️ #{ERB::Util.html_escape(error)}</p>" : ''

    <<~HTML
      <!doctype html>
      <html lang="pt-BR">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Liberar preço</title>
          <style>
            body{font-family:-apple-system,system-ui,Segoe UI,Roboto,sans-serif;background:#0f172a;
              color:#e2e8f0;margin:0;padding:24px}
            .card{background:#1e293b;padding:24px;border-radius:16px;max-width:520px;margin:0 auto}
            h1{font-size:19px;margin:0 0 16px}
            .product-row{border-bottom:1px solid #334155;padding:12px 0}
            .checkbox{display:flex;align-items:center;gap:8px;margin-bottom:8px}
            .row-fields{display:flex;flex-wrap:wrap;gap:12px;align-items:center;font-size:13px;color:#94a3b8}
            .row-fields label{display:flex;flex-direction:column;gap:2px}
            input[type=number]{background:#0f172a;border:1px solid #334155;color:#e2e8f0;
              border-radius:6px;padding:6px;width:100px}
            .custo{color:#64748b}
            button{margin-top:16px;background:#22c55e;color:#0f172a;border:none;border-radius:8px;
              padding:10px 20px;font-weight:600;cursor:pointer}
            .error{color:#f59e0b}
          </style>
        </head>
        <body>
          <div class="card">
            <h1>Escolha o que enviar pro cliente</h1>
            #{error_html}
            <form method="post" action="?phone=#{ERB::Util.url_encode(phone)}&internal_secret=#{ERB::Util.url_encode(secret)}">
              #{rows}
              <button type="submit">Enviar pro cliente</button>
            </form>
          </div>
          <script>
            document.querySelectorAll('.product-row').forEach(function (row) {
              var tabela = parseFloat(row.dataset.tabela || '0');
              var finalInput = row.querySelector('.preco-final');
              var percentInput = row.querySelector('.desconto-percent');
              var valorInput = row.querySelector('.desconto-valor');

              function fromPercent() {
                var pct = parseFloat(percentInput.value || '0');
                var valor = tabela * pct / 100;
                valorInput.value = valor.toFixed(2);
                finalInput.value = (tabela - valor).toFixed(2);
              }
              function fromValor() {
                var valor = parseFloat(valorInput.value || '0');
                var pct = tabela ? (valor / tabela * 100) : 0;
                percentInput.value = pct.toFixed(2);
                finalInput.value = (tabela - valor).toFixed(2);
              }
              function fromFinal() {
                var fin = parseFloat(finalInput.value || '0');
                var valor = tabela - fin;
                var pct = tabela ? (valor / tabela * 100) : 0;
                percentInput.value = pct.toFixed(2);
                valorInput.value = valor.toFixed(2);
              }
              percentInput.addEventListener('input', fromPercent);
              valorInput.addEventListener('input', fromValor);
              finalInput.addEventListener('input', fromFinal);
            });
          </script>
        </body>
      </html>
    HTML
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
