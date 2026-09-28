class AccessControl::TelephonyCallReportGrantSeeder
  def self.perform
    connection = ActiveRecord::Base.connection
    supported = connection.check_constraints(:access_role_grants).any? do |constraint|
      constraint.name == 'access_role_grants_supported_resource' && constraint.expression.include?('telephony_calls')
    end
    raise 'Bridge Telephony grant CHECK expansion is required before seeding' unless supported

    connection.select_value(<<~SQL.squish).to_i
      WITH inserted AS (
        INSERT INTO access_role_grants
          (account_id, access_role_id, resource, capability, access_scope, created_at, updated_at)
        SELECT access_roles.account_id, access_roles.id, 'telephony_calls', capabilities.capability, 'all',
               CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM access_roles CROSS JOIN (VALUES ('view'), ('view_reports')) AS capabilities(capability)
        WHERE access_roles.system_key = 'administrator'
        ON CONFLICT (access_role_id, resource, capability) DO NOTHING
        RETURNING id
      )
      SELECT COUNT(*) FROM inserted
    SQL
  end
end
