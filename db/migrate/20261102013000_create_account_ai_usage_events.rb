class CreateAccountAiUsageEvents < ActiveRecord::Migration[7.1]
  def up
    add_column :messages, :ai_usage_sent_at, :datetime
    create_table :account_ai_dialog_states do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :contact, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.jsonb :state, null: false, default: {}
      t.timestamps
    end
    add_index :account_ai_dialog_states, [:account_id, :contact_id], unique: true
    create_table :account_ai_usage_events do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :event_key, null: false
      t.string :bucket, null: false
      t.datetime :occurred_at, null: false
      t.integer :quantity, null: false
      t.timestamps
    end
    add_index :account_ai_usage_events, [:account_id, :event_key], unique: true
    preserve_historical_sources
  end

  def down
    drop_table :account_ai_usage_events
    drop_table :account_ai_dialog_states, if_exists: true
    remove_column :messages, :ai_usage_sent_at
  end

  private

  # Only seed identities into the new table: never recompute already billed counters. Old
  # acknowledged replies remain deduplicated after their 25-id legacy window has been rotated out.
  def preserve_historical_sources
    execute <<~SQL.squish
      INSERT INTO account_ai_usage_events (account_id, event_key, bucket, occurred_at, quantity, created_at, updated_at)
      SELECT messages.account_id, 'message:' || messages.id, 'captain_ai_dialogs_monthly', messages.created_at, 0, NOW(), NOW()
      FROM messages INNER JOIN inboxes ON inboxes.id = messages.inbox_id
      WHERE messages.message_type = 1 AND messages.private = FALSE AND messages.status <> 3
        AND (messages.additional_attributes ? 'captain_ai_reply' OR messages.additional_attributes ? 'captain_follow_up')
        AND (NULLIF(messages.source_id, '') IS NOT NULL OR messages.status IN (1, 2)
             OR inboxes.channel_type IN ('Channel::WebWidget', 'Channel::Api'))
      ON CONFLICT (account_id, event_key) DO NOTHING
    SQL
  end
end
