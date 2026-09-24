class AccessControl::EnforcementReadiness
  Result = Data.define(
    :account_id,
    :ready,
    :compatibility_counts,
    :missing_system_roles,
    :system_role_mismatches
  ) do
    def ready?
      ready
    end
  end

  def self.call(account:)
    new(account).call
  end

  def initialize(account)
    @account = account
  end

  def call
    compatibility = AccessControl::LegacyCompatibilityChecker.call(account: account)
    missing_roles, mismatched_roles = system_role_status
    blocked = compatibility.counts.except('matched').values.sum.positive?

    Result.new(
      account_id: account.id,
      ready: !blocked && missing_roles.empty? && mismatched_roles.empty?,
      compatibility_counts: compatibility.counts,
      missing_system_roles: missing_roles,
      system_role_mismatches: mismatched_roles
    )
  end

  private

  attr_reader :account

  def system_role_status
    roles = account.access_roles.where(system_key: AccessControl::SystemRoleCatalog::ROLE_NAMES.keys)
                   .includes(:grants).index_by(&:system_key)
    missing = AccessControl::SystemRoleCatalog::ROLE_NAMES.keys - roles.keys
    mismatched = roles.filter_map do |system_key, role|
      system_key unless grants_for(role) == expected_grants_for(system_key)
    end
    [missing.sort, mismatched.sort]
  end

  def grants_for(role)
    role.grants.filter_map do |grant|
      if AccessControl::FutureTelephonyGrant.valid?(grant)
        next if AccessControl::FutureTelephonyGrant.bridge_only? || role.system_key != 'administrator'

        # Preserve presence of both admin capabilities while allowing an explicit denial.
        [grant.resource, grant.capability, grant.access_scope == 'none' ? 'all' : grant.access_scope]
      else
        [grant.resource, grant.capability, grant.access_scope]
      end
    end.sort
  end

  def expected_grants_for(system_key)
    AccessControl::SystemRoleCatalog.grants_for(system_key).map do |grant|
      [grant.fetch(:resource), grant.fetch(:capability), grant.fetch(:access_scope)]
    end.sort
  end
end
