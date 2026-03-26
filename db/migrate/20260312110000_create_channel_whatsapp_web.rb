class CreateChannelWhatsappWeb < ActiveRecord::Migration[7.0]
  class LegacyApiChannel < ApplicationRecord
    self.table_name = 'channel_api'
  end

  class WhatsappWebChannel < ApplicationRecord
    self.table_name = 'channel_whatsapp_web'
  end

  class InboxRecord < ApplicationRecord
    self.table_name = 'inboxes'
  end

  def up
    create_table :channel_whatsapp_web do |t|
      t.integer :account_id, null: false
      t.string :phone_number, null: false
      t.string :provider, null: false, default: 'evolution'
      t.jsonb :provider_config, null: false, default: {}
      t.string :instance_name, null: false
      t.string :lifecycle_state, null: false, default: 'creating'
      t.string :connection_state, null: false, default: 'close'
      t.text :last_error
      t.datetime :last_synced_at
      t.jsonb :qr_code, null: false, default: {}
      t.string :webhook_identifier, null: false
      t.string :webhook_secret, null: false

      t.timestamps
    end

    add_index :channel_whatsapp_web, :instance_name, unique: true
    add_index :channel_whatsapp_web, :webhook_identifier, unique: true

    migrate_legacy_whatsapp_web_api_channels!
  end

  def down
    drop_table :channel_whatsapp_web
  end

  private

  def migrate_legacy_whatsapp_web_api_channels!
    legacy_channels = LegacyApiChannel.where("additional_attributes ->> 'provider' = ?", 'whatsapp_web')
    return if legacy_channels.blank?

    rows = legacy_channels.map do |legacy_channel|
      attrs = (legacy_channel.additional_attributes || {}).deep_stringify_keys
      evolution = attrs['evolution'] || {}
      number = normalize_number(attrs['number'] || evolution['number'])
      instance_name = evolution['instance_name'].presence || "onelink-waweb-#{legacy_channel.account_id}-#{number.presence || legacy_channel.identifier}"

      {
        account_id: legacy_channel.account_id,
        phone_number: number.present? ? "+#{number}" : '+000000000000',
        provider: 'evolution',
        provider_config: { migrated_from_channel_api_id: legacy_channel.id },
        instance_name: instance_name,
        lifecycle_state: normalize_lifecycle_state(evolution['status']),
        connection_state: normalize_connection_state(evolution['connection_state']),
        last_error: evolution['last_error'],
        last_synced_at: legacy_channel.updated_at,
        qr_code: (evolution['qrcode'] || {}).deep_stringify_keys,
        webhook_identifier: SecureRandom.base58(24),
        webhook_secret: SecureRandom.base58(24),
        created_at: legacy_channel.created_at,
        updated_at: legacy_channel.updated_at
      }
    end

    WhatsappWebChannel.insert_all!(rows)
    created_channels = WhatsappWebChannel.where(instance_name: rows.map { |row| row[:instance_name] }).index_by(&:instance_name)

    legacy_channels.each do |legacy_channel|
      attrs = (legacy_channel.additional_attributes || {}).deep_stringify_keys
      evolution = attrs['evolution'] || {}
      number = normalize_number(attrs['number'] || evolution['number'])
      instance_name = evolution['instance_name'].presence || "onelink-waweb-#{legacy_channel.account_id}-#{number.presence || legacy_channel.identifier}"
      new_channel = created_channels[instance_name]
      next if new_channel.blank?

      InboxRecord.where(channel_type: 'Channel::Api', channel_id: legacy_channel.id)
                .update_all(channel_type: 'Channel::WhatsappWeb', channel_id: new_channel.id)
    end

    LegacyApiChannel.where(id: legacy_channels.select(:id)).delete_all
  end

  def normalize_number(value)
    value.to_s.gsub(/\D/, '')
  end

  def normalize_lifecycle_state(value)
    case value.to_s
    when 'connected'
      'connected'
    when 'qr_ready'
      'qr_ready'
    when 'waiting_for_qr'
      'waiting_for_qr'
    when 'failed'
      'failed'
    when 'disconnected'
      'disconnected'
    else
      'creating'
    end
  end

  def normalize_connection_state(value)
    case value.to_s
    when 'open'
      'open'
    when 'connecting'
      'connecting'
    when 'refused'
      'refused'
    else
      'close'
    end
  end
end
