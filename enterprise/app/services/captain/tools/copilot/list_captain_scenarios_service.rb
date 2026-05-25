# frozen_string_literal: true

class Captain::Tools::Copilot::ListCaptainScenariosService < Captain::Tools::Copilot::CaptainScenarioAdminTool
  def self.name
    'list_captain_scenarios'
  end

  description 'List Captain scenarios in the current account for AI Admin operations'
  param :assistant_id, type: :integer, desc: 'Optional Captain assistant ID filter', required: false
  param :enabled, type: :boolean, desc: 'Optional enabled status filter', required: false
  param :limit, type: :number, desc: 'Maximum scenarios to return, capped at 50', required: false

  def execute(assistant_id: nil, enabled: nil, limit: nil)
    ensure_account_administrator!

    scenarios = scenarios_scope(assistant_id: assistant_id)
    scenarios = scenarios.where(enabled: cast_boolean(enabled)) unless enabled.nil?

    formatted_payload(
      action: 'list_captain_scenarios',
      total_count: scenarios.count,
      scenarios: scenarios.limit(parse_limit(limit, default: 25, max: 50)).map { |scenario| scenario_payload(scenario) }
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
