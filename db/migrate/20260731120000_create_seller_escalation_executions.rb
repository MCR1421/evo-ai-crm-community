class CreateSellerEscalationExecutions < ActiveRecord::Migration[7.1]
  def change
    create_table :seller_escalation_executions, id: :uuid do |t|
      t.uuid :conversation_id, null: false
      t.integer :rodada_index, null: false
      t.string :seller_phone, null: false
      t.datetime :notified_at, null: false
      t.timestamps
    end

    add_index :seller_escalation_executions, [:conversation_id, :rodada_index],
              unique: true, name: 'index_seller_escalation_on_conv_and_rodada'
    add_index :seller_escalation_executions, :conversation_id
  end
end
