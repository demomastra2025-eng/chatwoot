# frozen_string_literal: true

class Captain::Tools::Copilot::AssignUserToTeamService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'assign_user_to_team'
  end

  description 'Assign an account user to an account team'
  param :user_id, type: :number, desc: 'Account user ID to assign', required: true
  param :team_id, type: :number, desc: 'Account team ID', required: true

  def execute(user_id:, team_id:)
    ensure_account_administrator!

    account_user = account_user!(user_id)
    team = account.teams.find(team_id)
    was_member = team.members.exists?(id: account_user.user_id)
    team.add_members([account_user.user_id]) unless was_member

    formatted_payload(
      action: 'assign_user_to_team',
      team: team_payload(team.reload),
      user: account_user_payload(account_user.reload),
      added: !was_member
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
