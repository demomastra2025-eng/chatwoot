class AddSyncStateToChannelWhatsappWeb < ActiveRecord::Migration[7.0]
  def change
    add_column :channel_whatsapp_web, :sync_state, :jsonb, null: false, default: {}
  end
end
