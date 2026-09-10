class AccessControl::SystemRoleBootstrapper
  Result = Data.define(:roles_by_key, :created_roles, :created_grants)

  def self.call(account:)
    new(account).call
  end

  def initialize(account)
    @account = account
  end

  def call
    roles_by_key = {}
    created_roles = 0
    created_grants = 0

    account.with_lock do
      AccessControl::SystemRoleCatalog::ROLE_NAMES.each do |system_key, name|
        role, role_created = find_or_create_role(system_key, name)
        roles_by_key[system_key] = role
        created_roles += 1 if role_created
        created_grants += create_missing_grants(role, AccessControl::SystemRoleCatalog.grants_for(system_key))
      end
    end

    Result.new(roles_by_key: roles_by_key, created_roles: created_roles, created_grants: created_grants)
  end

  private

  attr_reader :account

  def find_or_create_role(system_key, name)
    role = account.access_roles.find_by(system_key: system_key)
    return [role, false] if role

    [account.access_roles.create!(system_key: system_key, name: name), true]
  end

  def create_missing_grants(role, definitions)
    expected = definitions.index_by { |grant| [grant[:resource], grant[:capability]] }
    role.grants.find_each do |grant|
      definition = expected.delete([grant.resource, grant.capability])
      definition ? reconcile_scope(grant, definition[:access_scope]) : grant.destroy!
    end

    missing = expected.values
    return 0 if missing.empty?

    missing.each { |grant| role.grants.create!(grant.merge(account: account)) }
    missing.size
  end

  def reconcile_scope(grant, expected_scope)
    grant.update!(access_scope: expected_scope) unless grant.access_scope == expected_scope
  end
end
