# frozen_string_literal: true

class Captain::Tools::Copilot::GetCaptainScenarioService < Captain::Tools::Copilot::CaptainScenarioAdminTool
  def self.name
    'get_captain_scenario'
  end

  description 'Get one Captain scenario from the current account with redacted instructions and tool references'
  param :scenario_id, type: :integer, desc: 'Captain scenario ID', required: true

  def execute(scenario_id:)
    ensure_account_administrator!

    scenario = find_scenario!(scenario_id)
    formatted_payload(action: 'get_captain_scenario', scenario: scenario_payload(scenario, include_instruction: true))
  rescue StandardError => e
    tool_failure(e)
  end
end
