require 'rails_helper'

RSpec.describe SellerEscalationExecution do
  let(:conversation_id) { SecureRandom.uuid }

  describe '.last_rodada_for' do
    it 'returns -1 when nothing was executed yet' do
      expect(described_class.last_rodada_for(conversation_id)).to eq(-1)
    end

    it 'returns the highest rodada_index recorded' do
      described_class.create!(conversation_id: conversation_id, rodada_index: 0, seller_phone: '5511900000001', notified_at: Time.current)
      described_class.create!(conversation_id: conversation_id, rodada_index: 2, seller_phone: '5511900000002', notified_at: Time.current)

      expect(described_class.last_rodada_for(conversation_id)).to eq(2)
    end
  end

  describe '.rodada_executed?' do
    it 'is false before the rodada was recorded and true after' do
      expect(described_class.rodada_executed?(conversation_id, 0)).to be(false)

      described_class.create!(conversation_id: conversation_id, rodada_index: 0, seller_phone: '5511900000001', notified_at: Time.current)

      expect(described_class.rodada_executed?(conversation_id, 0)).to be(true)
    end
  end

  describe 'uniqueness' do
    it 'refuses a duplicate (conversation_id, rodada_index) pair at the DB level' do
      described_class.create!(conversation_id: conversation_id, rodada_index: 0, seller_phone: '5511900000001', notified_at: Time.current)

      expect do
        described_class.create!(conversation_id: conversation_id, rodada_index: 0, seller_phone: '5511900000009', notified_at: Time.current)
      end.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe '.reset_for_conversation' do
    it 'deletes all executions for the conversation' do
      described_class.create!(conversation_id: conversation_id, rodada_index: 0, seller_phone: '5511900000001', notified_at: Time.current)

      described_class.reset_for_conversation(conversation_id)

      expect(described_class.where(conversation_id: conversation_id).count).to eq(0)
    end
  end
end
