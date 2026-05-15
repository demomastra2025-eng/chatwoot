# frozen_string_literal: true

class Captain::Tools::Copilot::ListTeamsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_teams'
  end

  description 'List account teams and optional members for assignment and routing decisions'
  param :query, type: :string, desc: 'Optional partial match against team name or description', required: false
  param :include_members, type: :boolean, desc: 'Whether to include team member IDs and names. Defaults to true', required: false
  param :limit, type: :number, desc: 'Maximum number of teams to return', required: false

  def execute(query: nil, include_members: true, limit: nil)
    teams = account.teams.order(:name, :id)
    teams = teams.where('LOWER(name) ILIKE :query OR LOWER(description) ILIKE :query', query: "%#{query.to_s.downcase}%") if query.present?

    total_count = teams.count
    include_member_payloads = cast_boolean(include_members, default: true)
    records = teams.limit(parse_limit(limit)).map { |team| team_payload(team, include_members: include_member_payloads) }

    formatted_payload(
      filters: { query: query }.compact,
      total_count: total_count,
      teams: records
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    operator_can_view_account_people?
  end

  private

  def operator_can_view_account_people?
    account_administrator? ||
      user_has_permission('conversation_manage') ||
      user_has_permission('conversation_unassigned_manage') ||
      user_has_permission('conversation_participating_manage') ||
      user_has_permission('crm_deal_view') ||
      user_has_permission('crm_deal_manage') ||
      user_has_permission('crm_task_view') ||
      user_has_permission('crm_task_manage')
  end

  def team_payload(team, include_members:)
    payload = {
      id: team.id,
      name: team.name,
      description: team.description,
      allow_auto_assign: team.allow_auto_assign,
      created_at: team.created_at&.iso8601,
      updated_at: team.updated_at&.iso8601
    }

    payload[:members] = members_payload_for(team.id) if include_members
    payload
  end

  def members_payload_for(team_id)
    team_members_by_team_id.fetch(team_id, [])
  end

  def team_members_by_team_id
    @team_members_by_team_id ||= TeamMember.includes(:user)
                                           .joins(:team)
                                           .where(teams: { account_id: account.id })
                                           .each_with_object({}) do |team_member, result|
      result[team_member.team_id] ||= []
      result[team_member.team_id] << {
        id: team_member.user_id,
        name: team_member.user.name,
        email: team_member.user.email
      }
    end
  end
end
