class CreateVirtualPbxDataModel < ActiveRecord::Migration[7.1]
  def change
    create_provider_connections
    create_sip_profiles
    extend_number_bindings
  end

  private

  def create_provider_connections
    create_table :telephony_provider_connections do |t|
      t.references :account, null: false, foreign_key: true
      t.string :provider_kind, null: false
      t.string :name, null: false
      t.string :host
      t.integer :port
      t.string :transport, null: false, default: 'udp'
      t.string :username
      t.string :password_secret_ref
      t.string :credentials_ref
      t.string :fonoster_trunk_ref
      t.string :fonoster_credentials_ref
      t.string :fonoster_acl_ref
      t.boolean :send_register, null: false, default: false
      t.string :status, null: false, default: 'draft'
      t.string :managed_by, null: false, default: 'onelink'
      t.string :ownership_status, null: false, default: 'local'
      t.jsonb :metadata, null: false, default: {}
      t.datetime :last_synced_at
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :updated_by, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :telephony_provider_connections,
              [:account_id, :provider_kind, :name],
              unique: true,
              name: 'idx_tel_provider_connections_account_kind_name'
    add_index :telephony_provider_connections,
              [:account_id, :fonoster_trunk_ref],
              unique: true,
              where: 'fonoster_trunk_ref IS NOT NULL',
              name: 'idx_tel_provider_connections_account_trunk_ref'
    add_index :telephony_provider_connections,
              [:account_id, :status],
              name: 'idx_tel_provider_connections_account_status'
  end

  def create_sip_profiles
    create_table :telephony_sip_profiles do |t|
      t.references :account, null: false, foreign_key: true
      t.references :inbox, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :provider_connection, foreign_key: { to_table: :telephony_provider_connections }
      t.string :internal_extension, null: false
      t.string :sip_username
      t.string :password_secret_ref
      t.string :sip_host
      t.string :agent_ref
      t.string :agent_aor
      t.string :fonoster_agent_ref
      t.string :credentials_ref
      t.string :fonoster_credentials_ref
      t.boolean :enabled, null: false, default: true
      t.string :availability_mode, null: false, default: 'external_extension'
      t.string :status, null: false, default: 'draft'
      t.string :managed_by, null: false, default: 'onelink'
      t.string :ownership_status, null: false, default: 'local'
      t.jsonb :metadata, null: false, default: {}
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :telephony_sip_profiles,
              [:account_id, :inbox_id, :user_id, :internal_extension],
              unique: true,
              name: 'idx_tel_sip_profiles_account_inbox_user_ext'
    add_index :telephony_sip_profiles,
              [:account_id, :agent_aor],
              unique: true,
              where: 'agent_aor IS NOT NULL',
              name: 'idx_tel_sip_profiles_account_agent_aor'
    add_index :telephony_sip_profiles,
              [:account_id, :agent_ref],
              unique: true,
              where: 'agent_ref IS NOT NULL',
              name: 'idx_tel_sip_profiles_account_agent_ref'
    add_index :telephony_sip_profiles,
              [:account_id, :provider_connection_id],
              name: 'idx_tel_sip_profiles_account_provider_connection'
  end

  def extend_number_bindings
    add_reference :telephony_number_bindings,
                  :provider_connection,
                  foreign_key: { to_table: :telephony_provider_connections }
    add_column :telephony_number_bindings, :display_phone_number, :string
    add_column :telephony_number_bindings, :provider_account_number, :string
    add_column :telephony_number_bindings, :ingress_number, :string
    add_column :telephony_number_bindings, :fonoster_tel_url, :string
    add_column :telephony_number_bindings, :managed_by, :string
    add_column :telephony_number_bindings, :ownership_status, :string, null: false, default: 'legacy_reference'

    add_index :telephony_number_bindings,
              [:account_id, :provider_connection_id],
              name: 'idx_tel_number_bindings_account_provider_connection'
    add_index :telephony_number_bindings,
              [:account_id, :ingress_number],
              name: 'idx_tel_number_bindings_account_ingress'
    add_index :telephony_number_bindings,
              [:account_id, :ownership_status],
              name: 'idx_tel_number_bindings_account_ownership'
  end
end
