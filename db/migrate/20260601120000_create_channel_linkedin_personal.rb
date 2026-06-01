class CreateChannelLinkedinPersonal < ActiveRecord::Migration[7.0]
  def change
    create_table :channel_linkedin_personal do |t|
      t.integer :account_id, null: false
      t.string :profile_urn, null: false
      t.string :display_name
      t.text :li_at
      t.text :jsessionid
      t.text :csrf_token
      t.text :x_li_track
      t.string :connection_state, null: false, default: 'disconnected'
      t.string :lifecycle_state, null: false, default: 'pending_auth'
      t.text :last_error
      t.datetime :last_synced_at
      t.string :webhook_identifier, null: false
      t.string :webhook_secret, null: false
      t.jsonb :runtime_state, null: false, default: {}

      t.timestamps
    end

    add_index :channel_linkedin_personal, :account_id
    add_index :channel_linkedin_personal, [:account_id, :profile_urn], unique: true
    add_index :channel_linkedin_personal, :webhook_identifier, unique: true
  end
end
