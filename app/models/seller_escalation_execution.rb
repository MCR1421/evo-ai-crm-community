class SellerEscalationExecution < ApplicationRecord
  validates :rodada_index, presence: true, uniqueness: { scope: :conversation_id }
  validates :seller_phone, presence: true
  validates :notified_at, presence: true

  scope :for_conversation, ->(conversation_id) { where(conversation_id: conversation_id) }

  def self.last_rodada_for(conversation_id)
    for_conversation(conversation_id).maximum(:rodada_index) || -1
  end

  def self.rodada_executed?(conversation_id, rodada_index)
    exists?(conversation_id: conversation_id, rodada_index: rodada_index)
  end

  def self.reset_for_conversation(conversation_id)
    for_conversation(conversation_id).destroy_all
  end
end
