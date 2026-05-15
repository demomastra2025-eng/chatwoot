# frozen_string_literal: true

class Captain::Tools::Copilot::DeleteCaptainScenarioService < Captain::Tools::Copilot::CaptainScenarioAdminTool
  def self.name
    'delete_captain_scenario'
  end

  description 'Delete a Captain scenario from the current account. Requires operator confirmation.'
  param :scenario_id, type: :integer, desc: 'Captain scenario ID', required: true

  def execute(scenario_id:)
    ensure_account_administrator!

    scenario = find_scenario!(scenario_id)
    before_payload = scenario_payload(scenario, include_instruction: true)
    scenario.destroy!

    formatted_payload(action: 'delete_captain_scenario', deleted_scenario: before_payload)
  rescue StandardError => e
    tool_failure(e)
  end
end
