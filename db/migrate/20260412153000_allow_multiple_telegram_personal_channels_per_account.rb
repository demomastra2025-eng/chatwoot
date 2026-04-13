class AllowMultipleTelegramPersonalChannelsPerAccount < ActiveRecord::Migration[7.0]
  def change
    remove_index :channel_telegram_personal, :account_id
    add_index :channel_telegram_personal, :account_id
  end
end
