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
    ensure_account_user!(actor) if actor.present?
    ensure_account_user!(assignee) if assignee.present?
    ensure_account_team!(team) if team.present?
    ensure_team_membership!(assignee, team) if assignee.present? && team.present?
    true
  end

  private

  attr_reader :account, :actor, :assignee, :team

  def ensure_account_user!(user)
    return if account.users.exists?(id: user.id)

    deny_assignment!
  end

  def ensure_account_team!(candidate_team)
    return if account.teams.exists?(id: candidate_team.id)

    deny_assignment!
  end

  def ensure_team_membership!(candidate_assignee, candidate_team)
    return if TeamMember.exists?(team_id: candidate_team.id, user_id: candidate_assignee.id)

    deny_assignment!
  end

  def deny_assignment!
    raise Crm::Error.new(
      code: 'TASK_ASSIGNMENT_FORBIDDEN',
      message: 'Task assignee or team is outside the account assignment scope',
      status: :forbidden,
      details: { assignee_id: assignee&.id, team_id: team&.id }
    )
  end
end
