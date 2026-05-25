# frozen_string_literal: true

class Captain::Tools::Copilot::SetCaptainScenarioStatusService < Captain::Tools::Copilot::CaptainScenarioAdminTool
  def self.name
    'set_captain_scenario_status'
  end

  description 'Enable or disable a Captain scenario. Requires operator confirmation.'
  param :scenario_id, type: :integer, desc: 'Captain scenario ID', required: true
  param :enabled, type: :boolean, desc: 'True to enable, false to disable', required: true

  def execute(scenario_id:, enabled:)
    ensure_account_administrator!

    scenario = find_scenario!(scenario_id)
    before_payload = scenario_payload(scenario, include_instruction: true)
    scenario.update!(enabled: cast_boolean(enabled))

    formatted_payload(
      action: 'set_captain_scenario_status',
      scenario: scenario_payload(scenario.reload, include_instruction: true),
      previous_scenario: before_payload,
      updated_fields: ['enabled']
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
