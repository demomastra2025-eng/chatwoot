class AddTelegramNotifications < ActiveRecord::Migration[7.1]
  def change
    add_column :notification_settings, :telegram_flags, :integer, default: 0, null: false

    create_table :telegram_notification_bindings do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :telegram_user_id
      t.string :telegram_chat_id
      t.string :username
      t.string :first_name
      t.string :last_name
      t.datetime :verified_at

      t.timestamps
    end

    add_index :telegram_notification_bindings, :telegram_user_id, unique: true, where: 'telegram_user_id IS NOT NULL'
  end
end
