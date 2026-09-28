# db:chatwoot_prepare runs while old web/workers can still delete unknown grants.
# Leave this version as a schema prerequisite; the post-cutover finalizer owns the data seed.
# B + expanded DB remains the minimum rollback floor after that finalizer runs.
class SeedTelephonyCallReportAdministratorGrants < ActiveRecord::Migration[7.1]
  def up
    unless connection.check_constraints(:access_role_grants).any? do |constraint|
      constraint.name == 'access_role_grants_supported_resource' && constraint.expression.include?('telephony_calls')
    end
      raise ActiveRecord::MigrationError, 'Bridge Telephony grant CHECK expansion is required before seeding'
    end

    # No data writes: older bootstrap code deletes unknown Telephony grants, including
    # grants for accounts created after this migration but before web/worker cutover.
  end

  def down
    # B writers, native opt-ins and explicit denials must survive a T2 -> B rollback.
  end
end
