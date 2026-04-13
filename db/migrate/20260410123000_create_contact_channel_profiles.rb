class CreateContactChannelProfiles < ActiveRecord::Migration[7.1]
  def change
    create_table :contact_channel_profiles do |t|
      t.references :account, null: false, foreign_key: true
      t.references :contact, null: false, foreign_key: true
      t.references :contact_inbox, null: false, foreign_key: true, index: false
      t.references :inbox, null: false, foreign_key: true
      t.string :channel_type, null: false
      t.string :provider, null: false
      t.text :source_id, null: false
      t.string :identifier
      t.string :display_name
      t.text :avatar_url
      t.string :username
      t.string :phone_number
      t.string :email
      t.jsonb :profile_data, default: {}, null: false
      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :contact_channel_profiles, :contact_inbox_id, unique: true, name: 'idx_contact_channel_profiles_unique_contact_inbox'
    add_index :contact_channel_profiles, [:account_id, :provider, :source_id], name: 'idx_contact_channel_profiles_provider_source'
    add_index :contact_channel_profiles, [:contact_id, :inbox_id], name: 'idx_contact_channel_profiles_contact_inbox'
  end
end
