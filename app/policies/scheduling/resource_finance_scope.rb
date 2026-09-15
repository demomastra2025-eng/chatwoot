class Scheduling::ResourceFinanceScope < ApplicationPolicy::Scope
  def resolve
    account_scope = account.present? ? scope.where(account_id: account.id) : scope.none
    return missing_account_user_scope(account_scope) if account_user.blank?

    mode_resolution = AccessControl::ModeResolver.call(
      account_user: account_user,
      resource: 'appointments',
      capability: 'view_finance'
    )
    instrument_shadow_scope(mode_resolution)
    return account_scope unless mode_resolution.authoritative_source == 'access_role'

    apply(account_scope, mode_resolution.access_role_resolution&.scope || 'none')
  end

  private

  def apply(account_scope, access_scope)
    return account_scope if access_scope == 'all'
    return account_scope.where(user_id: user.id) if access_scope == 'own'
    return account_scope.none unless access_scope == 'team'

    team_ids = TeamMember.joins(:team).where(user_id: user.id, teams: { account_id: account.id }).select(:team_id)
    account_scope.where(
      'scheduling_resources.user_id = :user_id OR scheduling_resources.team_id IN (:team_ids)',
      user_id: user.id,
      team_ids: team_ids
    )
  end

  def missing_account_user_scope(account_scope)
    return account_scope if account.blank?

    AccessControl::ModeResolver.mode_for_account(account.id) == 'enforced' ? account_scope.none : account_scope
  end

  def instrument_shadow_scope(mode_resolution)
    return unless mode_resolution.mode == 'shadow'

    AccessControl::ModeAwareDecision.instrument_shadow_scope(mode_resolution: mode_resolution, legacy_scope: 'all')
  end
end
