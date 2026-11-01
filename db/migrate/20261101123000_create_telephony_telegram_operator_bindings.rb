class CreateTelephonyTelegramOperatorBindings < ActiveRecord::Migration[7.1]
  def change
    create_table :telephony_telegram_operator_bindings do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :telegram_user_id
      t.string :telegram_chat_id
      t.string :username
      t.string :first_name
      t.string :last_name
      t.string :phone_number
      t.string :link_token_digest
      t.datetime :link_token_expires_at
      t.datetime :verified_at
      t.boolean :on_line, default: false, null: false
      t.datetime :on_line_since
      t.jsonb :sip_lease_meta, default: {}, null: false
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end

    add_bridge_indexes
  end

  private

  def add_bridge_indexes
    add_index :telephony_telegram_operator_bindings, [:account_id, :user_id],
              unique: true, name: 'idx_tel_tg_operator_bindings_account_user'
    add_index :telephony_telegram_operator_bindings, [:account_id, :telegram_user_id],
              unique: true, where: "telegram_user_id IS NOT NULL AND telegram_user_id <> ''",
              name: 'idx_tel_tg_operator_bindings_account_tg_user'
    add_index :telephony_telegram_operator_bindings, :telegram_user_id,
              where: 'telegram_user_id IS NOT NULL', name: 'idx_tel_tg_operator_bindings_tg_user'
    add_index :telephony_telegram_operator_bindings, :link_token_digest,
              unique: true, where: 'link_token_digest IS NOT NULL', name: 'idx_tel_tg_operator_bindings_link_token'
  end
end
