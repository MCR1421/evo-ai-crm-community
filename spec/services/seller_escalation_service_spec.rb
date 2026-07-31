require 'rails_helper'

RSpec.describe SellerEscalationService do
  include ActiveSupport::Testing::TimeHelpers

  let(:phone) { '5522999990000' }
  let(:sellers) do
    [
      { 'nome' => 'Vendedor A', 'telefone' => '5511900000001' },
      { 'nome' => 'Vendedor B', 'telefone' => '5511900000002' }
    ]
  end
  let(:conversation_id) { SecureRandom.uuid }
  let(:gate) { PriceGateService.new(phone) }

  after do
    gate.clear!
    SellerEscalationExecution.reset_for_conversation(conversation_id)
  end

  describe '#escalate_if_due!' do
    it 'does nothing when there is no pending gate for this phone' do
      service = described_class.new(phone, sellers: sellers)

      expect { service.escalate_if_due! }.not_to change(SellerEscalationExecution, :count)
    end

    it 'does nothing when the gate is already released' do
      gate.register_pending(conversation_id: conversation_id, agent_bot_id: 'bot-1', quote: {})
      gate.release!

      service = described_class.new(phone, sellers: sellers)

      expect { service.escalate_if_due! }.not_to change(SellerEscalationExecution, :count)
    end

    it 'does nothing before the first rodada window (25 minutes) has elapsed' do
      gate.register_pending(conversation_id: conversation_id, agent_bot_id: 'bot-1', quote: {})

      service = described_class.new(phone, sellers: sellers)

      expect { service.escalate_if_due! }.not_to change(SellerEscalationExecution, :count)
    end

    it 'records rodada 0 and notifies the first seller once 25 minutes have elapsed' do
      gate.register_pending(conversation_id: conversation_id, agent_bot_id: 'bot-1', quote: {})
      expect(SellerNotifier).to receive(:call).with(seller_phone: '5511900000001', message: a_string_including('LEAD ESCALADO'))

      travel 26.minutes do
        service = described_class.new(phone, sellers: sellers)
        service.escalate_if_due!
      end

      expect(SellerEscalationExecution.rodada_executed?(conversation_id, 0)).to be(true)
    end

    it 'does not double-notify the same rodada on a second call within the same window' do
      gate.register_pending(conversation_id: conversation_id, agent_bot_id: 'bot-1', quote: {})
      allow(SellerNotifier).to receive(:call)

      travel 26.minutes do
        described_class.new(phone, sellers: sellers).escalate_if_due!
        described_class.new(phone, sellers: sellers).escalate_if_due!
      end

      expect(SellerNotifier).to have_received(:call).once
    end

    it 'stops after MAX_RODADAS and sends the critical alert wording' do
      gate.register_pending(conversation_id: conversation_id, agent_bot_id: 'bot-1', quote: {})
      allow(SellerNotifier).to receive(:call)

      travel((25 * 6 + 1).minutes) do
        described_class.new(phone, sellers: sellers).escalate_if_due!
      end

      expect(SellerEscalationExecution.last_rodada_for(conversation_id)).to eq(5)
      expect(SellerNotifier).to have_received(:call).with(hash_including(message: a_string_including('ALERTA CRÍTICO')))
    end
  end
end
