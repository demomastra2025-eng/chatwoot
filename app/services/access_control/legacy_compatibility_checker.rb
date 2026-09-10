class AccessControl::LegacyCompatibilityChecker
  Entry = Data.define(
    :account_user_id,
    :lifecycle_snapshot_id,
    :user_id,
    :status,
    :expected_identity,
    :actual_identity,
    :differences,
    :details
  )
  Result = Data.define(:account_id, :entries) do
    def counts
      entries.group_by(&:status).transform_values(&:size)
    end
  end

  def self.call(account:)
    new(account).call
  end

  def initialize(account)
    @account = account
  end

  def call
    entries = compatibility_subjects.map { |subject| compare(subject) }
    Result.new(account_id: account.id, entries: entries)
  end

  private

  attr_reader :account

  def compatibility_subjects
    account.account_users.includes(:custom_role, access_role: :grants).find_each.to_a +
      AccountUserLifecycleSnapshot.active.where(account_id: account.id).includes(:custom_role, access_role: :grants).find_each.to_a
  end

  def compare(account_user)
    return unresolved_entry(account_user, 'conflict', 'administrator_with_custom_role') if administrator_with_custom_role?(account_user)

    expectation = expectation_for(account_user)
    return unsupported_entry(account_user, expectation) unless expectation.fetch(:unsupported_permissions).empty?

    expected_identity = expectation.fetch(:identity)
    actual_identity = identity_for(account_user.access_role)
    differences = grant_differences(account_user, expectation.fetch(:grants))
    details = []
    details << 'identity_mismatch' unless actual_identity == expected_identity
    details << 'grant_mismatch' if differences.any?
    status = details.empty? ? 'matched' : 'mismatch'

    entry(
      account_user,
      status: status,
      expected_identity: expected_identity,
      actual_identity: actual_identity,
      differences: differences,
      details: details
    )
  end

  def expectation_for(account_user)
    return custom_role_expectation(account_user.custom_role) if account_user.custom_role

    system_key = account_user.role == 'administrator' ? 'administrator' : 'employee'
    {
      identity: { system_key: system_key, legacy_custom_role_id: nil },
      grants: AccessControl::SystemRoleCatalog.grants_for(system_key),
      unsupported_permissions: []
    }
  end

  def custom_role_expectation(custom_role)
    analysis = AccessControl::LegacyCustomRoleMapper.analyze(custom_role)
    {
      identity: { system_key: nil, legacy_custom_role_id: custom_role.id },
      grants: analysis.grants,
      unsupported_permissions: analysis.unsupported_permissions
    }
  end

  def grant_differences(account_user, expected_grants)
    expected_scopes = scopes_by_key(expected_grants)
    actual_keys = account_user.access_role&.grants&.map { |grant| [grant.resource, grant.capability] } || []
    keys = (expected_scopes.keys + actual_keys).uniq.sort
    resolver = AccessControl::ShadowResolver.new(account_user)

    keys.filter_map do |resource, capability|
      expected_scope = expected_scopes.fetch([resource, capability], 'none')
      actual_scope = resolver.call(resource: resource, capability: capability).scope
      next if actual_scope == expected_scope

      { resource: resource, capability: capability, expected_scope: expected_scope, actual_scope: actual_scope }
    end
  end

  def scopes_by_key(grants)
    grants.to_h do |grant|
      [[grant.fetch(:resource), grant.fetch(:capability)], grant.fetch(:access_scope)]
    end
  end

  def identity_for(role)
    return unless role

    { system_key: role.system_key, legacy_custom_role_id: role.legacy_custom_role_id }
  end

  def administrator_with_custom_role?(account_user)
    account_user.role == 'administrator' && account_user.custom_role_id?
  end

  def unsupported_entry(account_user, expectation)
    entry(
      account_user,
      status: 'review_required',
      expected_identity: expectation.fetch(:identity),
      actual_identity: identity_for(account_user.access_role),
      differences: [],
      details: expectation.fetch(:unsupported_permissions)
    )
  end

  def unresolved_entry(account_user, status, detail)
    entry(
      account_user,
      status: status,
      expected_identity: nil,
      actual_identity: identity_for(account_user.access_role),
      differences: [],
      details: [detail]
    )
  end

  def entry(subject, **attributes)
    Entry.new(
      account_user_id: subject.is_a?(AccountUser) ? subject.id : nil,
      lifecycle_snapshot_id: subject.is_a?(AccountUserLifecycleSnapshot) ? subject.id : nil,
      user_id: subject.user_id,
      **attributes
    )
  end
end
