class AddNativeSettingsToChannelWhatsappWeb < ActiveRecord::Migration[7.0]
  def change
    change_table :channel_whatsapp_web, bulk: true do |t|
      t.boolean :conversation_pending, default: false, null: false
      t.integer :history_lookback_days, default: 365, null: false
      t.jsonb :ignore_jids, default: [], null: false
      t.boolean :sign_messages, default: false, null: false
      t.string :sign_delimiter, default: '\\n', null: false
      t.boolean :import_contacts, default: true, null: false
      t.boolean :import_messages, default: true, null: false
      t.boolean :sync_labels, default: true, null: false
    end
  end
end
