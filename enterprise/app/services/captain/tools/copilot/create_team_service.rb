# frozen_string_literal: true

class Captain::Tools::Copilot::CreateTeamService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'create_team'
  end

  description 'Create an account team for routing, assignment, and ownership workflows'
  param :name, type: :string, desc: 'Team name', required: true
  param :description, type: :string, desc: 'Optional team description', required: false
  param :allow_auto_assign, type: :boolean, desc: 'Whether conversations can be auto-assigned to this team. Defaults to true', required: false
  param :member_user_ids, type: :string, desc: 'Optional comma-separated account user IDs to add as initial members', required: false

  def execute(name:, description: nil, allow_auto_assign: true, member_user_ids: nil)
    ensure_account_administrator!

    raise ArgumentError, 'name is required' if name.blank?

    users = account_users_for_ids!(member_user_ids)
    team = account.teams.create!(
      name: name,
      description: description,
      allow_auto_assign: cast_boolean(allow_auto_assign, default: true)
    )
    team.add_members(users.map(&:id)) if users.any?

    formatted_payload(action: 'create_team', team: team_payload(team.reload))
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def account_users_for_ids!(value)
    ids = parse_id_list(value, field_name: 'member_user_ids')
    return [] if ids.blank?

    users = account.users.where(id: ids).to_a
    missing = ids - users.map(&:id)
    raise ActiveRecord::RecordNotFound, "Account users not found: #{missing.join(', ')}" if missing.any?

    users
  end
end
