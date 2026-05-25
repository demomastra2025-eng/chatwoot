# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateTeamService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'update_team'
  end

  description 'Update account team metadata such as name, description, and auto-assignment'
  param :team_id, type: :number, desc: 'Account team ID to update', required: true
  param :name, type: :string, desc: 'Optional team name', required: false
  param :description, type: :string, desc: 'Optional team description. Empty string clears it.', required: false
  param :allow_auto_assign, type: :boolean, desc: 'Optional auto-assignment toggle for the team', required: false

  def execute(team_id:, **kwargs)
    ensure_account_administrator!

    team = account.teams.find(team_id)
    attributes = team_update_attributes(kwargs)
    raise ArgumentError, 'No supported team fields were provided' if attributes.blank?

    team.update!(attributes)

    formatted_payload(
      action: 'update_team',
      team: team_payload(team.reload),
      updated_fields: attributes.keys.map(&:to_s)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def team_update_attributes(kwargs)
    attributes = {}
    attributes[:name] = kwargs[:name].to_s if kwargs.key?(:name) && kwargs[:name].present?
    attributes[:description] = kwargs[:description].to_s if kwargs.key?(:description)
    attributes[:allow_auto_assign] = cast_boolean(kwargs[:allow_auto_assign]) if kwargs.key?(:allow_auto_assign)
    attributes
  end
end
