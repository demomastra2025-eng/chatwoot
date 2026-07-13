class CreateMetaChannelCredentialHealths < ActiveRecord::Migration[7.1]
  def change
    create_table :meta_channel_credential_healths do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :channel, polymorphic: true, null: false, index: false
      t.string :status, null: false, default: 'unknown'
      t.string :reason
      t.integer :provider_code
      t.integer :provider_subcode
      t.string :provider_type
      t.string :provider_trace_id
      t.datetime :expires_at, :data_access_expires_at, :checked_at, :last_healthy_at, :last_failed_at
      t.integer :consecutive_failures, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_health_indexes
    backfill_initial_health_rows
  end

  private

  def add_health_indexes
    add_index :meta_channel_credential_healths, [:channel_type, :channel_id],
              unique: true, name: 'index_meta_channel_credential_healths_on_channel'
    add_index :meta_channel_credential_healths, [:account_id, :status],
              name: 'index_meta_channel_credential_healths_on_account_status'
  end

  def backfill_initial_health_rows
    reversible do |direction|
      direction.up do
        backfill_channel_table('channel_instagram', 'Channel::Instagram')
        backfill_channel_table('channel_facebook_pages', 'Channel::FacebookPage')
        backfill_whatsapp_health
      end
    end
  end

  def backfill_channel_table(table_name, channel_type)
    execute <<~SQL.squish
      INSERT INTO meta_channel_credential_healths
        (account_id, channel_type, channel_id, status, reason, metadata, consecutive_failures, created_at, updated_at)
      SELECT account_id, '#{channel_type}', id, 'unknown', 'legacy_backfill_pending', '{}'::jsonb, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM #{table_name}
      ON CONFLICT (channel_type, channel_id) DO NOTHING
    SQL
  end

  # rubocop:disable Metrics/MethodLength
  def backfill_whatsapp_health
    execute <<~SQL.squish
      INSERT INTO meta_channel_credential_healths
        (account_id, channel_type, channel_id, status, reason, metadata, consecutive_failures, created_at, updated_at)
      SELECT
        account_id,
        'Channel::Whatsapp',
        id,
        CASE provider_config->'token_health'->>'status'
          WHEN 'healthy' THEN 'healthy'
          WHEN 'expiring' THEN 'expiring'
          WHEN 'healthy_unverified' THEN 'degraded'
          WHEN 'invalid' THEN 'action_required'
          WHEN 'permission_missing' THEN 'action_required'
          WHEN 'app_id_mismatch' THEN 'action_required'
          WHEN 'waba_access_missing' THEN 'action_required'
          WHEN 'phone_number_mismatch' THEN 'action_required'
          ELSE 'unknown'
        END,
        COALESCE(provider_config->'token_health'->>'status', 'legacy_backfill_pending'),
        '{}'::jsonb,
        0,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM channel_whatsapp
      ON CONFLICT (channel_type, channel_id) DO NOTHING
    SQL
  end
  # rubocop:enable Metrics/MethodLength
end
