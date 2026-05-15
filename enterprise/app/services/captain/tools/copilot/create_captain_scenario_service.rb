# frozen_string_literal: true

class Captain::Tools::Copilot::CreateCaptainScenarioService < Captain::Tools::Copilot::CaptainScenarioAdminTool
  def self.name
    'create_captain_scenario'
  end

  description 'Create a Captain scenario for one assistant. Requires operator confirmation.'
  param :assistant_id, type: :integer, desc: 'Captain assistant ID', required: true
  param :title, type: :string, desc: 'Scenario title', required: true
  param :description, type: :string, desc: 'Scenario routing description', required: true
  param :instruction, type: :string, desc: 'Scenario instructions. May include tool:// references.', required: true
  param :tool_ids_json, type: :string, desc: 'Optional JSON array of scenario tool IDs to append as managed tool:// references', required: false
  param :enabled, type: :boolean, desc: 'Whether the scenario is enabled. Defaults to true.', required: false

  def execute(assistant_id:, title:, description:, instruction:, **kwargs)
    ensure_account_administrator!

    scenario_assistant = find_scenario_assistant!(assistant_id)
    scenario = scenario_assistant.scenarios.create!(
      account: account,
      title: title,
      description: description,
      instruction: apply_tool_references(instruction, scenario_assistant, kwargs[:tool_ids_json]),
      enabled: kwargs[:enabled].nil? || cast_boolean(kwargs[:enabled])
    )

    formatted_payload(action: 'create_captain_scenario', scenario: scenario_payload(scenario.reload, include_instruction: true))
  rescue StandardError => e
    tool_failure(e)
  end
end
