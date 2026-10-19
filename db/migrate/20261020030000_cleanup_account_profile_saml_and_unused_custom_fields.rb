class CleanupAccountProfileSamlAndUnusedCustomFields < ActiveRecord::Migration[7.1]
  def up
    remove_column :accounts, :domain, :string, if_exists: true
    remove_column :accounts, :support_email, :string, if_exists: true
    drop_table :account_saml_settings, if_exists: true

    if table_exists?(:custom_attribute_definitions)
      execute 'DELETE FROM custom_attribute_definitions WHERE attribute_model = 0'
    end

    if table_exists?(:crm_field_definitions)
      execute "DELETE FROM crm_field_definitions WHERE entity_kind = 'task'"
    end

    if table_exists?(:crm_tasks) && column_exists?(:crm_tasks, :custom_attributes)
      execute "UPDATE crm_tasks SET custom_attributes = '{}'::jsonb WHERE custom_attributes IS NOT NULL AND custom_attributes != '{}'::jsonb"
    end
  end

  def down
    add_column :accounts, :domain, :string, limit: 100 unless column_exists?(:accounts, :domain)
    add_column :accounts, :support_email, :string, limit: 100 unless column_exists?(:accounts, :support_email)

    return if table_exists?(:account_saml_settings)

    create_table :account_saml_settings do |t|
      t.bigint :account_id, null: false
      t.string :sso_url
      t.text :certificate
      t.string :sp_entity_id
      t.string :idp_entity_id
      t.json :role_mappings, default: {}
      t.timestamps
      t.index :account_id
    end
  end
end
