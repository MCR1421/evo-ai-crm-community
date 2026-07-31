class PriceGateService
  TTL = 30.minutes

  def initialize(phone)
    @phone = phone
    @key = "price_gate:#{phone}"
  end

  def released?
    state['released'] == true
  end

  def register_pending(conversation_id:, agent_bot_id:, quote:)
    current = state
    requested_at = current['requested_at'] || Time.current.iso8601

    Redis::Alfred.setex(@key, current.merge(
      'released' => current['released'] || false,
      'conversation_id' => conversation_id,
      'agent_bot_id' => agent_bot_id,
      'quote' => quote,
      'requested_at' => requested_at
    ).to_json, TTL)
  end

  def release!
    current = state
    Redis::Alfred.setex(@key, current.merge('released' => true).to_json, TTL)
  end

  def pending_quote
    state['quote']
  end

  def pending_conversation_id
    state['conversation_id']
  end

  def pending_agent_bot_id
    state['agent_bot_id']
  end

  def requested_at
    raw = state['requested_at']
    raw ? Time.zone.parse(raw) : nil
  end

  def clear!
    Redis::Alfred.delete(@key)
  end

  private

  def state
    raw = Redis::Alfred.get(@key)
    raw ? JSON.parse(raw) : {}
  end
end
