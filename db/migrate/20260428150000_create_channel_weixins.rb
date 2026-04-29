class CreateChannelWeixins < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_weixins do |t|
      t.integer :account_id, null: false
      t.text :ilink_token
      t.string :token_fingerprint
      t.string :provider_account_id
      t.string :display_name
      t.text :context_token
      t.string :connection_state, null: false, default: 'disconnected'
      t.string :lifecycle_state, null: false, default: 'pending_auth'
      t.text :last_error
      t.datetime :last_synced_at
      t.jsonb :runtime_state, null: false, default: {}
      t.string :webhook_identifier, null: false
      t.string :webhook_secret, null: false
      t.timestamps
    end

    add_index :channel_weixins, :account_id
    add_index :channel_weixins, :webhook_identifier, unique: true
    add_index :channel_weixins, [:account_id, :token_fingerprint], unique: true
    add_index :channel_weixins, [:account_id, :provider_account_id], unique: true, where: 'provider_account_id IS NOT NULL'
  end
end
