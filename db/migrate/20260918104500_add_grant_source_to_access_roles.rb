class AddGrantSourceToAccessRoles < ActiveRecord::Migration[7.0]
  def change
    add_column :access_roles, :grant_source, :string, null: false, default: 'legacy'
    add_check_constraint :access_roles,
                         "grant_source IN ('legacy', 'canonical')",
                         name: 'chk_access_roles_grant_source'
    add_index :access_roles, [:account_id, :grant_source]
  end
end
