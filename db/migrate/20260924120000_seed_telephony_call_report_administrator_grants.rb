# Run only after the bridge CHECK expansion and after every pre-bridge writer has drained.
# This migration changes data only; B + expanded DB remains the minimum rollback floor.
class SeedTelephonyCallReportAdministratorGrants < ActiveRecord::Migration[7.1]
  def up
    unless connection.check_constraints(:access_role_grants).any? do |constraint|
      constraint.name == 'access_role_grants_supported_resource' && constraint.expression.include?('telephony_calls')
    end
      raise ActiveRecord::MigrationError, 'Bridge Telephony grant CHECK expansion is required before seeding'
    end

    execute <<~SQL.squish
      INSERT INTO access_role_grants
        (account_id, access_role_id, resource, capability, access_scope, created_at, updated_at)
      SELECT access_roles.account_id, access_roles.id, 'telephony_calls', capabilities.capability, 'all',
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM access_roles CROSS JOIN (VALUES ('view'), ('view_reports')) AS capabilities(capability)
      WHERE access_roles.system_key = 'administrator'
      ON CONFLICT (access_role_id, resource, capability) DO NOTHING
    SQL
  end

  def down
    # B writers, native opt-ins and explicit denials must survive a T2 -> B rollback.
  end
end
