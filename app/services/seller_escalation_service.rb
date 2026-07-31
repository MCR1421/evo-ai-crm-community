class SellerEscalationService
  MAX_RODADAS = 6
  MINUTES_PER_RODADA = 25

  def initialize(phone, sellers:)
    @phone = phone
    @sellers = sellers
    @gate = PriceGateService.new(phone)
  end

  def escalate_if_due!
    return unless @gate.pending_conversation_id
    return if @gate.released?

    elapsed_minutes = ((Time.current - @gate.requested_at) / 60.0).floor
    return if elapsed_minutes < MINUTES_PER_RODADA

    rodada_index = [elapsed_minutes / MINUTES_PER_RODADA - 1, MAX_RODADAS - 1].min
    return if rodada_index <= SellerEscalationExecution.last_rodada_for(conversation_id)

    notify_for_rodada(rodada_index)
  end

  private

  def conversation_id
    @gate.pending_conversation_id
  end

  def notify_for_rodada(rodada_index)
    seller = @sellers[rodada_index % @sellers.length]
    is_final = rodada_index >= MAX_RODADAS - 1

    message = if is_final
      "🆘 *ALERTA CRÍTICO — CLIENTE SEM RESPOSTA*\n" \
      "Esse lead já passou por #{rodada_index + 1} vendedores sem resposta. " \
      "Esse é o ÚLTIMO aviso automático — o cliente é seu agora, por favor priorize."
    else
      "🚨 *LEAD ESCALADO PRA VOCÊ*\n" \
      "O vendedor anterior não respondeu em ~#{MINUTES_PER_RODADA}min — o lead é seu agora."
    end

    SellerEscalationExecution.create!(
      conversation_id: conversation_id,
      rodada_index: rodada_index,
      seller_phone: seller['telefone'],
      notified_at: Time.current
    )

    SellerNotifier.call(seller_phone: seller['telefone'], message: message)
  rescue ActiveRecord::RecordInvalid
    # Another cron tick already recorded this rodada first — exactly the race
    # the old Redis counter allowed; the DB unique index makes this a no-op here.
    nil
  end
end
