class ExpandTelephonyCallGrantChecksForCompatibility < ActiveRecord::Migration[7.1]
  PREVIOUS_RESOURCE_CAPABILITIES = {
    'contacts' => %w[view create update_fields assign delete_archive view_configuration configure export view_reports],
    'conversations' => %w[view create update_fields assign transition take delete_archive view_configuration configure export view_reports],
    'appointments' => %w[
      view create update_fields assign transition delete_archive view_finance manage_finance view_configuration configure export
      view_reports override_schedule
    ],
    'deals' => %w[view create update_fields assign transition delete_archive view_configuration configure export view_reports],
    'tasks' => %w[view create update_fields assign transition complete_cancel delete_archive view_configuration configure export view_reports],
    'automation_rules' => %w[manage]
  }.freeze
  RESOURCE_CAPABILITIES = PREVIOUS_RESOURCE_CAPABILITIES.merge('telephony_calls' => %w[view view_reports]).freeze
  CONSTRAINT_NAMES = %w[
    access_role_grants_supported_resource_capability
    access_role_grants_supported_capability
    access_role_grants_supported_resource
  ].freeze

  def up
    # Schema-only: no Telephony grants may exist until every old writer has been replaced.
    refresh_constraints!(RESOURCE_CAPABILITIES)
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM access_role_grants WHERE resource = 'telephony_calls')")
      raise ActiveRecord::IrreversibleMigration, 'Telephony grants exist; the expanded schema is the minimum rollback floor'
    end

    refresh_constraints!(PREVIOUS_RESOURCE_CAPABILITIES)
  end

  private

  def refresh_constraints!(resource_capabilities)
    CONSTRAINT_NAMES.each { |name| remove_check_constraint :access_role_grants, name: name }

    add_check_constraint :access_role_grants,
                         "resource IN (#{quoted_list(resource_capabilities.keys)})",
                         name: 'access_role_grants_supported_resource'
    add_check_constraint :access_role_grants,
                         "capability IN (#{quoted_list(resource_capabilities.values.flatten.uniq)})",
                         name: 'access_role_grants_supported_capability'
    add_check_constraint :access_role_grants,
                         supported_resource_capability_expression(resource_capabilities),
                         name: 'access_role_grants_supported_resource_capability'
  end

  def supported_resource_capability_expression(resource_capabilities)
    resource_capabilities.map do |resource, capabilities|
      scope_clause = resource == 'automation_rules' ? " AND access_scope IN ('none', 'all')" : ''
      "(resource = #{connection.quote(resource)} AND capability IN (#{quoted_list(capabilities)})#{scope_clause})"
    end.join(' OR ')
  end

  def quoted_list(values)
    values.map { |value| connection.quote(value) }.join(', ')
  end
end
