class Crm::Tasks::RealtimeRecipients
  def initialize(account:, task:, changes: {})
    @account = account
    @task = task
    @changes = changes.to_h.stringify_keys
  end

  def tokens
    return legacy_tokens unless enforced?

    account.account_users.includes(:user).filter_map do |account_user|
      account_user.user&.pubsub_token if visible_for_scope?(account_user.user, grants_by_role_id[account_user.access_role_id])
    end.uniq
  end

  private

  attr_reader :account, :task, :changes

  def enforced?
    AccessControl::ModeResolver.mode_for_account(account.id) == 'enforced'
  end

  def legacy_tokens
    ["account_#{account.id}"]
  end

  def grants_by_role_id
    @grants_by_role_id ||= AccessRoleGrant.where(
      account_id: account.id,
      resource: 'tasks',
      capability: 'view'
    ).pluck(:access_role_id, :access_scope).to_h
  end

  def visible_for_scope?(user, access_scope)
    case access_scope
    when 'all'
      true
    when 'team'
      assignee_ids.include?(user.id) || team_ids.intersect?(user_team_ids(user))
    when 'own'
      assignee_ids.include?(user.id)
    else
      false
    end
  end

  def assignee_ids
    @assignee_ids ||= boundary_ids('assignee_id', task.assignee_id)
  end

  def team_ids
    @team_ids ||= boundary_ids('team_id', task.team_id)
  end

  def boundary_ids(key, current_id)
    values = changes[key].presence || [current_id]
    Array(values).compact.map(&:to_i).uniq
  end

  def user_team_ids(user)
    TeamMember.joins(:team)
              .where(user_id: user.id, teams: { account_id: account.id })
              .pluck(:team_id)
  end
end
