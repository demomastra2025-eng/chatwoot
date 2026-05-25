# frozen_string_literal: true

class Captain::Tools::Copilot::RemoveUserFromTeamService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'remove_user_from_team'
  end

  description 'Remove an account user from an account team'
  param :user_id, type: :number, desc: 'Account user ID to remove from the team', required: true
  param :team_id, type: :number, desc: 'Account team ID', required: true

  def execute(user_id:, team_id:)
    ensure_account_administrator!

    account_user = account_user!(user_id)
    team = account.teams.find(team_id)
    was_member = team.members.exists?(id: account_user.user_id)
    team.remove_members([account_user.user_id]) if was_member

    formatted_payload(
      action: 'remove_user_from_team',
      team: team_payload(team.reload),
      user: account_user_payload(account_user.reload),
      removed: was_member
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
