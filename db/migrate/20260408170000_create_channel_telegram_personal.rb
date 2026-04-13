class CreateChannelTelegramPersonal < ActiveRecord::Migration[7.0]
  def change
    create_table :channel_telegram_personal do |t|
      t.integer :account_id, null: false
      t.integer :api_id, null: false
      t.string :api_hash
      t.string :phone_number, null: false
      t.text :string_session
      t.string :connection_state, null: false, default: 'disconnected'
      t.string :lifecycle_state, null: false, default: 'pending_auth'
      t.text :last_error
      t.datetime :last_synced_at
      t.string :webhook_identifier, null: false
      t.string :webhook_secret, null: false
      t.jsonb :runtime_state, null: false, default: {}

      t.timestamps
    end

    add_index :channel_telegram_personal, :phone_number, unique: true
    add_index :channel_telegram_personal, :webhook_identifier, unique: true
  end
end
