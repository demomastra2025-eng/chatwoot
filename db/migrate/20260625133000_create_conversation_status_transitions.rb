class CreateConversationStatusTransitions < ActiveRecord::Migration[7.1]
  def change
    create_table :conversation_status_transitions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true
      t.references :actor, polymorphic: true, index: true
      t.string :from_status, null: false
      t.string :to_status, null: false
      t.string :reason
      t.string :source, null: false, default: 'manual'
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :conversation_status_transitions,
              [:account_id, :conversation_id, :created_at],
              name: 'idx_conv_status_transitions_on_account_conversation_created'
    add_index :conversation_status_transitions,
              [:account_id, :to_status, :created_at],
              name: 'idx_conv_status_transitions_on_account_status_created'
  end
end
