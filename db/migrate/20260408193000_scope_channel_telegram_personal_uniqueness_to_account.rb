class ScopeChannelTelegramPersonalUniquenessToAccount < ActiveRecord::Migration[7.0]
  def change
    remove_index :channel_telegram_personal, :phone_number
    add_index :channel_telegram_personal, :account_id, unique: true
    add_index :channel_telegram_personal, [:account_id, :phone_number],
              unique: true,
              name: 'index_channel_telegram_personal_on_account_phone'
  end
end
