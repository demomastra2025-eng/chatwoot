class AccessControl::ShadowResolver
  Result = Data.define(:account_user_id, :access_role_id, :resource, :capability, :scope, :status, :reason)

  def self.call(account_user:, resource:, capability:)
    new(account_user).call(resource: resource, capability: capability)
  end

  def initialize(account_user)
    @account_user = account_user
  end

  def call(resource:, capability:)
    validate_query!(resource, capability)
    role = account_user.access_role
    return result(resource, capability, 'none', 'unresolved', 'missing_access_role') unless role
    return result(resource, capability, 'none', 'unresolved', 'cross_account_access_role') unless role.account_id == account_user.account_id

    scope = grant_scopes.fetch([resource, capability], 'none')
    result(resource, capability, scope, 'resolved', scope == 'none' ? 'missing_grant' : nil)
  end

  private

  attr_reader :account_user

  def validate_query!(resource, capability)
    capabilities = AccessRoleGrant::RESOURCE_CAPABILITIES.fetch(resource) do
      raise ArgumentError, "Unsupported resource: #{resource}"
    end
    return if capabilities.include?(capability)

    raise ArgumentError, "Unsupported capability for #{resource}: #{capability}"
  end

  def grant_scopes
    @grant_scopes ||= account_user.access_role.grants.to_h do |grant|
      [[grant.resource, grant.capability], grant.access_scope]
    end
  end

  def result(resource, capability, scope, status, reason)
    Result.new(
      account_user_id: account_user.id,
      access_role_id: account_user.access_role_id,
      resource: resource,
      capability: capability,
      scope: scope,
      status: status,
      reason: reason
    )
  end
end
