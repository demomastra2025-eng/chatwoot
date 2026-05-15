# frozen_string_literal: true

class Captain::Tools::Copilot::ArchiveTeamService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'archive_team'
  end

  description 'Archive an account team by removing it from routing and assignment. Existing conversations are detached by the domain model.'
  param :team_id, type: :number, desc: 'Account team ID to archive', required: true

  def execute(team_id:)
    ensure_account_administrator!

    team = account.teams.find(team_id)
    payload = team_payload(team, include_members: false)
    member_ids = team.members.pluck(:id)
    team.destroy!

    formatted_payload(
      action: 'archive_team',
      archived_team: payload,
      removed_member_ids: member_ids,
      archived: true
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
