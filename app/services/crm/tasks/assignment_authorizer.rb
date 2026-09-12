class Crm::Tasks::AssignmentAuthorizer
  def self.call(account:, actor:, assignee:, team:)
    new(account: account, actor: actor, assignee: assignee, team: team).call
  end

  def initialize(account:, actor:, assignee:, team:)
    @account = account
    @actor = actor
    @assignee = assignee
    @team = team
  end

  def call
    return true if actor.blank?

    account_user = account.account_users.find_by(user: actor)
    return missing_account_user_result if account_user.blank?

    mode_resolution = AccessControl::ModeResolver.call(
      account_user: account_user,
      resource: 'tasks',
      capability: 'assign'
    )
    allowed = assignment_allowed?(mode_resolution.access_role_resolution&.scope || 'none')
    authorized = AccessControl::ModeAwareDecision.call(
      mode_resolution: mode_resolution,
      legacy_allowed: true,
      access_role_allowed: allowed
    )
    return true if authorized

    deny_assignment!
  end

  def deny_assignment!
    raise Crm::Error.new(
      code: 'TASK_ASSIGNMENT_FORBIDDEN',
      message: 'Task assignee or team is outside the assignment scope',
      status: :forbidden,
      details: { assignee_id: assignee&.id, team_id: team&.id }
    )
  end

  private

  attr_reader :account, :actor, :assignee, :team

  def missing_account_user_result
    return true unless AccessControl::ModeResolver.mode_for_account(account.id) == 'enforced'

    deny_assignment!
  end

  def assignment_allowed?(access_scope)
    case access_scope
    when 'all' then valid_team_membership?
    when 'team' then team_assignment_allowed?
    when 'own' then assignee == actor && (team.blank? || actor_team_ids.include?(team.id))
    else false
    end
  end

  def team_assignment_allowed?
    return assignee == actor if team.blank?
    return false unless actor_team_ids.include?(team.id)

    assignee.blank? || TeamMember.exists?(team_id: team.id, user_id: assignee.id)
  end

  def valid_team_membership?
    team.blank? || assignee.blank? || TeamMember.exists?(team_id: team.id, user_id: assignee.id)
  end

  def actor_team_ids
    @actor_team_ids ||= TeamMember.joins(:team)
                                  .where(user_id: actor.id, teams: { account_id: account.id })
                                  .pluck(:team_id)
  end
end
