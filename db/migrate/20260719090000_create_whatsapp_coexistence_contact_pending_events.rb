class CreateWhatsappCoexistenceContactPendingEvents < ActiveRecord::Migration[7.1]
  BACKFILL_SQL = <<~SQL.squish.freeze
    INSERT INTO whatsapp_coexistence_contact_pending_events
      (account_id, channel_id, event_key, reason, entry, created_at, updated_at)
    SELECT
      channel.account_id,
      channel.id,
      event->>'key',
      COALESCE(event->>'reason', 'missing_contact_identity'),
      event->'entry',
      CURRENT_TIMESTAMP,
      CURRENT_TIMESTAMP
    FROM channel_whatsapp channel
    CROSS JOIN LATERAL jsonb_array_elements(
      COALESCE(channel.provider_config->'coexistence_sync'->'contacts_pending_events', '[]'::jsonb)
    ) event
    WHERE event->>'key' IS NOT NULL AND event->'entry' IS NOT NULL
    ON CONFLICT (channel_id, event_key) DO NOTHING
  SQL

  def change
    create_table :whatsapp_coexistence_contact_pending_events do |t|
      t.references :account, type: :integer, null: false, foreign_key: { on_delete: :cascade }
      t.references :channel, null: false, foreign_key: { to_table: :channel_whatsapp, on_delete: :cascade }
      t.string :event_key, null: false
      t.string :reason, null: false
      t.jsonb :entry, null: false, default: {}
      t.timestamps
    end

    add_index :whatsapp_coexistence_contact_pending_events, [:channel_id, :event_key],
              unique: true, name: 'idx_wa_coex_contact_pending_channel_event'
    add_index :whatsapp_coexistence_contact_pending_events, [:account_id, :channel_id, :id],
              name: 'idx_wa_coex_contact_pending_account_channel'
    backfill_provider_config_events
  end

  private

  def backfill_provider_config_events
    reversible do |direction|
      direction.up { execute(BACKFILL_SQL) }
    end
  end
end
