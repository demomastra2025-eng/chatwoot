class CreateWhatsappPendingMessageMutations < ActiveRecord::Migration[7.1]
  def change
    create_table :whatsapp_pending_message_mutations do |t|
      t.references :account, type: :integer, null: false, foreign_key: { on_delete: :cascade }
      t.references :inbox, null: false, foreign_key: { on_delete: :cascade }
      t.string :event_id, null: false
      t.string :target_source_id, null: false
      t.string :mutation_type, null: false
      t.string :actor_id
      t.bigint :provider_timestamp, null: false, default: 0
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end

    add_index :whatsapp_pending_message_mutations, [:inbox_id, :event_id],
              unique: true, name: 'idx_wa_pending_mutations_inbox_event'
    add_index :whatsapp_pending_message_mutations, [:inbox_id, :target_source_id, :provider_timestamp],
              name: 'idx_wa_pending_mutations_target_time'
    add_index :whatsapp_pending_message_mutations, [:account_id, :inbox_id, :id],
              name: 'idx_wa_pending_mutations_account_inbox'
  end
end
