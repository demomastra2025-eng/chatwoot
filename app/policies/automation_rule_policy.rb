class AutomationRulePolicy < ApplicationPolicy
  def index?
    manage?
  end

  def create?
    manage?
  end

  def show?
    manage?
  end

  def update?
    manage?
  end

  def clone?
    manage?
  end

  def destroy?
    manage?
  end

  private

  def manage?
    return false unless same_account?

    legacy_allowed = account_user.administrator? || has_permission?('automation_manage')
    mode_resolution = AccessControl::ModeResolver.call(
      account_user: account_user,
      resource: 'automation_rules',
      capability: 'manage'
    )
    return true if account_user.administrator? && automation_grant_rollout_pending?(mode_resolution)

    AccessControl::ModeAwareDecision.call(
      mode_resolution: mode_resolution,
      legacy_allowed: legacy_allowed,
      access_role_allowed: mode_resolution.access_role_resolution&.scope == 'all'
    )
  end

  def automation_grant_rollout_pending?(mode_resolution)
    mode_resolution.mode == 'enforced' &&
      AccessControl::SystemRoleCatalog::BOOTSTRAP_RESOURCES.exclude?('automation_rules')
  end

  def same_account?
    return false if account_user.blank? || account.blank? || account_user.account_id != account.id
    return true if record == AutomationRule

    record.account_id == account.id
  end
end
