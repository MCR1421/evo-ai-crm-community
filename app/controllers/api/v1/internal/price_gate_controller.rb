class Api::V1::Internal::PriceGateController < ActionController::API
  before_action :verify_internal_secret

  def check
    phone = params.require(:phone)
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
    phone = params.require(:phone)
    gate = PriceGateService.new(phone)

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

  private

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
    provided = request.headers['X-Internal-Secret']
    expected = ENV.fetch('INTERNAL_TOOLS_SECRET')

    return if ActiveSupport::SecurityUtils.secure_compare(provided.to_s, expected)

    render json: { error: 'Unauthorized' }, status: :unauthorized
  end
end
