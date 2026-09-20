class Crm::TaskPolicy < Crm::BasePolicy
  def self.legacy_view_allowed?(account_user)
    return false if account_user.blank?

    permissions = Array(account_user.permissions)
    permissions.include?('administrator') ||
      (account_user.custom_role_id.blank? && permissions.include?('agent')) ||
      permissions.intersect?(%w[crm_task_view crm_task_manage])
  end

  class Scope < Crm::BasePolicy::Scope
    def initialize(user_context, scope, capability: 'view')
      super(user_context, scope)
      @capability = capability
    end

    def resolve
      account_scope = super
      return missing_account_user_scope(account_scope) if account_user.blank?

      mode_resolution = AccessControl::ModeResolver.call(
        account_user: account_user,
        resource: 'tasks',
        capability: capability
      )
      instrument_shadow_scope(mode_resolution)
      return legacy_scope(account_scope) unless mode_resolution.authoritative_source == 'access_role'

      self.class.apply(
        account_scope,
        access_scope: mode_resolution.access_role_resolution&.scope || 'none',
        user: user,
        account: account
      )
    end

    def self.apply(relation, access_scope:, user:, account:)
      case access_scope
      when 'all'
        relation
      when 'team'
        team_ids = TeamMember.joins(:team).where(user_id: user.id, teams: { account_id: account.id }).select(:team_id)
        relation.where(assignee_id: user.id).or(relation.where(team_id: team_ids))
      when 'own'
        relation.where(assignee_id: user.id)
      else
        relation.none
      end
    end

    def self.intersection(user_context, relation, capabilities:)
      Array(capabilities).reduce(relation) do |effective_scope, capability|
        capability_scope = new(user_context, relation, capability: capability.to_s).resolve
        effective_scope.where(id: capability_scope.select(:id))
      end
    end

    private

    attr_reader :capability

    def legacy_scope(account_scope)
      legacy_scope_allowed? ? account_scope : account_scope.none
    end

    def legacy_scope_allowed?
      permissions = Array(account_user.permissions)
      return ::Crm::TaskPolicy.legacy_view_allowed?(account_user) if capability == 'view'
      return permissions.include?('administrator') || permissions.include?('report_manage') if capability == 'view_reports'

      permissions.include?('administrator') ||
        (account_user.custom_role_id.blank? && permissions.include?('agent')) ||
        permissions.include?('crm_task_manage')
    end

    def missing_account_user_scope(account_scope)
      return account_scope if account.blank?

      AccessControl::ModeResolver.mode_for_account(account.id) == 'enforced' ? account_scope.none : account_scope
    end

    def instrument_shadow_scope(mode_resolution)
      return unless mode_resolution.mode == 'shadow'

      legacy_scope = legacy_scope_allowed? ? 'all' : 'none'
      AccessControl::ModeAwareDecision.instrument_shadow_scope(mode_resolution: mode_resolution, legacy_scope: legacy_scope)
    end
  end

  def index?
    task_access?(:view, record_scoped: false)
  end

  def show?
    task_access?(:view)
  end

  def timeline?
    task_access?(:view)
  end

  def view_reports?
    task_access?(:view_reports, record_scoped: false)
  end

  def create?
    task_access?(:create, record_scoped: false)
  end

  def update?
    task_access?(:update_fields)
  end

  alias save_form? update?
  alias reschedule? update?

  def assign?
    task_access?(:assign, record_scoped: record != ::Crm::Task)
  end

  def change_status?
    task_access?(:transition)
  end

  alias reopen? change_status?

  def complete?
    task_access?(:complete_cancel)
  end

  alias cancel? complete?

  def archive?
    task_access?(:delete_archive)
  end

  alias unarchive? archive?

  private

  def task_access?(capability, record_scoped: true)
    legacy_allowed = legacy_task_access?(capability)
    return legacy_allowed if account_user.blank?

    mode_resolution = AccessControl::ModeResolver.call(
      account_user: account_user,
      resource: 'tasks',
      capability: capability.to_s
    )
    access_scope = mode_resolution.access_role_resolution&.scope || 'none'
    AccessControl::ModeAwareDecision.call(
      mode_resolution: mode_resolution,
      legacy_allowed: legacy_allowed,
      access_role_allowed: task_access_role_allowed?(access_scope, record_scoped)
    )
  end

  def task_access_role_allowed?(access_scope, record_scoped)
    return access_scope != 'none' unless record_scoped

    Scope.apply(
      account.crm_tasks,
      access_scope: access_scope,
      user: user,
      account: account
    ).exists?(id: record.id)
  end

  def legacy_task_access?(capability)
    return self.class.legacy_view_allowed?(account_user) if capability == :view
    return administrator_access? || has_permission?('report_manage') if capability == :view_reports

    task_manage_access?
  end
end
