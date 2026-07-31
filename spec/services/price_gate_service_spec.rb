require 'rails_helper'

RSpec.describe PriceGateService do
  include ActiveSupport::Testing::TimeHelpers

  let(:phone) { '5522999990000' }
  let(:service) { described_class.new(phone) }

  after { Redis::Alfred.delete("price_gate:#{phone}") }

  describe '#released?' do
    it 'is false when nothing was registered' do
      expect(service.released?).to be(false)
    end

    it 'is true after #release! was called' do
      service.register_pending(conversation_id: 'conv-1', agent_bot_id: 'bot-1', quote: { 'produto' => 'Alternador Bosch' })
      service.release!

      expect(service.released?).to be(true)
    end
  end

  describe '#register_pending / #pending_quote' do
    it 'stores and returns the cached quote and originating conversation/agent_bot' do
      service.register_pending(conversation_id: 'conv-1', agent_bot_id: 'bot-1', quote: { 'produto' => 'Alternador Bosch' })

      expect(service.pending_quote).to eq({ 'produto' => 'Alternador Bosch' })
      expect(service.pending_conversation_id).to eq('conv-1')
      expect(service.pending_agent_bot_id).to eq('bot-1')
      expect(service.requested_at).to be_within(2.seconds).of(Time.current)
    end

    it 'does not overwrite requested_at on a second register_pending call (clock keeps running from the first block)' do
      service.register_pending(conversation_id: 'conv-1', agent_bot_id: 'bot-1', quote: { 'produto' => 'A' })
      first_requested_at = service.requested_at

      travel 5.minutes do
        service.register_pending(conversation_id: 'conv-1', agent_bot_id: 'bot-1', quote: { 'produto' => 'B (retry)' })
        expect(service.requested_at).to eq(first_requested_at)
        expect(service.pending_quote).to eq({ 'produto' => 'B (retry)' })
      end
    end
  end
end
