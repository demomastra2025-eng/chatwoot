class AccessControl::LegacyRoleAssigner
  Entry = Data.define(:account_user_id, :lifecycle_snapshot_id, :user_id, :status, :access_role_id, :details)
  Result = Data.define(:account_id, :apply, :entries) do
    def counts
      entries.group_by(&:status).transform_values(&:size)
    end
  end

  def self.call(account:, apply: false)
    new(account, apply: apply).call
  end

  def initialize(account, apply:)
    @account = account
    @apply = apply
  end

  def call
    return build_result(existing_system_roles) unless apply

    account.with_lock do
      roles_by_key = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
      build_result(roles_by_key)
    end
  end

  private

  attr_reader :account, :apply

  def build_result(roles_by_key)
    entries = assignment_subjects.map do |subject|
      classify_with_lock(subject, roles_by_key)
    end

    Result.new(account_id: account.id, apply: apply, entries: entries)
  end

  def assignment_subjects
    account.account_users.includes(:access_role, :custom_role).find_each.to_a +
      AccountUserLifecycleSnapshot.active.where(account_id: account.id).includes(:access_role, :custom_role).find_each.to_a
  end

  def classify_with_lock(subject, roles_by_key)
    return classify_and_assign(subject, roles_by_key) unless apply

    subject.with_lock do
      subject.reload
      classify_and_assign(subject, roles_by_key)
    end
  end

  def classify_and_assign(account_user, roles_by_key)
    if administrator_with_custom_role?(account_user)
      clear_assignment(account_user)
      return entry(account_user, 'conflict', nil, 'administrator_with_custom_role')
    end

    if account_user.custom_role
      assign_custom_role(account_user)
    else
      assign_system_role(account_user, roles_by_key)
    end
  end

  def administrator_with_custom_role?(account_user)
    account_user.role == 'administrator' && account_user.custom_role_id?
  end

  def assign_custom_role(account_user)
    analysis = AccessControl::LegacyCustomRoleMapper.analyze(account_user.custom_role)
    unless analysis.mappable?
      clear_assignment(account_user)
      return review_required_entry(account_user, analysis)
    end

    role = if apply
             AccessControl::LegacyCustomRoleMapper.call(custom_role: account_user.custom_role)
           else
             account_user.custom_role.access_role
           end
    return entry(account_user, 'already_assigned', role.id) if role && account_user.access_role_id == role.id

    account_user.update!(access_role: role) if apply
    entry(account_user, 'assigned_custom_role', role&.id, account_user.custom_role_id.to_s)
  end

  def assign_system_role(account_user, roles_by_key)
    system_key = account_user.role == 'administrator' ? 'administrator' : 'employee'
    role = roles_by_key[system_key]
    return entry(account_user, 'already_assigned', role.id) if role && account_user.access_role_id == role.id

    account_user.update!(access_role: role) if apply
    entry(account_user, "assigned_#{system_key}", role&.id)
  end

  def clear_assignment(account_user)
    account_user.update!(access_role: nil) if apply && account_user.access_role_id?
  end

  def existing_system_roles
    account.access_roles.where(system_key: AccessControl::SystemRoleCatalog::ROLE_NAMES.keys).index_by(&:system_key)
  end

  def entry(subject, status, access_role_id, details = nil)
    Entry.new(
      account_user_id: subject.is_a?(AccountUser) ? subject.id : nil,
      lifecycle_snapshot_id: subject.is_a?(AccountUserLifecycleSnapshot) ? subject.id : nil,
      user_id: subject.user_id,
      status: status,
      access_role_id: access_role_id,
      details: details
    )
  end

  def review_required_entry(account_user, analysis)
    entry(account_user, 'review_required', nil, analysis.unsupported_permissions.join(','))
  end
end
