# rubocop:disable Metrics/MethodLength
class CreateAccessRoleFoundation < ActiveRecord::Migration[7.1]
  RESOURCE_CAPABILITIES = {
    'contacts' => %w[view create update_fields assign delete_archive view_configuration configure export view_reports],
    'conversations' => %w[view create update_fields assign transition take delete_archive view_configuration configure export view_reports],
    'appointments' => %w[
      view create update_fields assign transition delete_archive view_configuration configure export view_reports override_schedule
    ],
    'deals' => %w[view create update_fields assign transition delete_archive view_configuration configure export view_reports],
    'tasks' => %w[view create update_fields assign transition complete_cancel delete_archive view_configuration configure export view_reports]
  }.freeze
  RESOURCES = RESOURCE_CAPABILITIES.keys.freeze
  CAPABILITIES = RESOURCE_CAPABILITIES.values.flatten.uniq.freeze
  ACCESS_SCOPES = %w[none own team all].freeze
  SYSTEM_KEYS = %w[administrator department_lead employee commercial_director observer].freeze

  def up
    create_access_roles
    create_access_role_grants
  end

  def down
    drop_table :access_role_grants
    drop_table :access_roles
  end

  private

  def create_access_roles
    create_table :access_roles do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :description
      t.string :system_key
      t.references :legacy_custom_role, index: false, foreign_key: { to_table: :custom_roles }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :access_roles, [:account_id, :id], unique: true, name: 'index_access_roles_on_account_and_id'
    add_index :access_roles,
              [:account_id, :system_key],
              unique: true,
              where: 'system_key IS NOT NULL',
              name: 'index_access_roles_on_account_and_system_key'
    add_index :access_roles,
              'account_id, lower(name)',
              unique: true,
              name: 'index_access_roles_on_account_and_lower_name'
    add_index :access_roles,
              :legacy_custom_role_id,
              unique: true,
              where: 'legacy_custom_role_id IS NOT NULL',
              name: 'index_access_roles_on_legacy_custom_role'
    add_check_constraint :access_roles,
                         "system_key IS NULL OR system_key IN (#{quoted_list(SYSTEM_KEYS)})",
                         name: 'access_roles_supported_system_key'
    add_check_constraint :access_roles,
                         "btrim(name) <> ''",
                         name: 'access_roles_non_blank_name'
    add_check_constraint :access_roles,
                         'system_key IS NULL OR legacy_custom_role_id IS NULL',
                         name: 'access_roles_single_identity_source'
    add_foreign_key :access_roles,
                    :custom_roles,
                    column: [:account_id, :legacy_custom_role_id],
                    primary_key: [:account_id, :id],
                    name: 'fk_access_roles_legacy_custom_role_account'
  end

  def create_access_role_grants
    create_table :access_role_grants do |t|
      t.references :account, null: false, foreign_key: true
      t.references :access_role, null: false, foreign_key: true
      t.string :resource, null: false
      t.string :capability, null: false
      t.string :access_scope, null: false
      t.timestamps
    end

    add_index :access_role_grants,
              [:access_role_id, :resource, :capability],
              unique: true,
              name: 'index_access_role_grants_on_role_resource_capability'
    add_index :access_role_grants,
              [:account_id, :resource, :capability, :access_scope],
              name: 'index_access_role_grants_on_account_lookup'
    add_check_constraint :access_role_grants,
                         "resource IN (#{quoted_list(RESOURCES)})",
                         name: 'access_role_grants_supported_resource'
    add_check_constraint :access_role_grants,
                         "capability IN (#{quoted_list(CAPABILITIES)})",
                         name: 'access_role_grants_supported_capability'
    add_check_constraint :access_role_grants,
                         supported_resource_capability_expression,
                         name: 'access_role_grants_supported_resource_capability'
    add_check_constraint :access_role_grants,
                         "access_scope IN (#{quoted_list(ACCESS_SCOPES)})",
                         name: 'access_role_grants_supported_scope'
    add_foreign_key :access_role_grants,
                    :access_roles,
                    column: [:account_id, :access_role_id],
                    primary_key: [:account_id, :id],
                    name: 'fk_access_role_grants_role_account'
  end

  def quoted_list(values)
    values.map { |value| connection.quote(value) }.join(', ')
  end

  def supported_resource_capability_expression
    RESOURCE_CAPABILITIES.map do |resource, capabilities|
      "(resource = #{connection.quote(resource)} AND capability IN (#{quoted_list(capabilities)}))"
    end.join(' OR ')
  end
end
# rubocop:enable Metrics/MethodLength
