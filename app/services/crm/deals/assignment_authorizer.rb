class Crm::Deals::AssignmentAuthorizer
  def self.call(account:, actor:, owner:, team:)
    new(account: account, actor: actor, owner: owner, team: team).call
  end

  def initialize(account:, actor:, owner:, team:)
    @account = account
    @actor = actor
    @owner = owner
    @team = team
  end

  def call
    ensure_account_user!(actor) if actor.present?
    ensure_account_user!(owner) if owner.present?
    ensure_account_team!(team) if team.present?
    ensure_team_membership!(owner, team) if owner.present? && team.present?
    true
  end

  private

  attr_reader :account, :actor, :owner, :team

  def ensure_account_user!(user)
    return if account.users.exists?(id: user.id)

    deny_assignment!
  end

  def ensure_account_team!(candidate_team)
    return if account.teams.exists?(id: candidate_team.id)

    deny_assignment!
  end

  def ensure_team_membership!(candidate_owner, candidate_team)
    return if TeamMember.exists?(team_id: candidate_team.id, user_id: candidate_owner.id)

    deny_assignment!
  end

  def deny_assignment!
    raise Crm::Error.new(
      code: 'DEAL_ASSIGNMENT_FORBIDDEN',
      message: 'Deal owner or team is outside the account assignment scope',
      status: :forbidden,
      details: { owner_id: owner&.id, team_id: team&.id }
    )
  end
end
