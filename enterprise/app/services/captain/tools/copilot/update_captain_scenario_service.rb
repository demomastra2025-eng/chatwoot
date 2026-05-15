# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateCaptainScenarioService < Captain::Tools::Copilot::CaptainScenarioAdminTool
  def self.name
    'update_captain_scenario'
  end

  TOOL_IDS_JSON_DESCRIPTION = 'Optional JSON array of scenario tool IDs to replace the managed tool:// reference block'

  description 'Update a Captain scenario profile, instructions, tool references, or enabled status. Requires operator confirmation.'
  param :scenario_id, type: :integer, desc: 'Captain scenario ID', required: true
  param :title, type: :string, desc: 'Optional scenario title', required: false
  param :description, type: :string, desc: 'Optional scenario routing description', required: false
  param :instruction, type: :string, desc: 'Optional full scenario instructions. May include tool:// references.', required: false
  param :tool_ids_json, type: :string, desc: TOOL_IDS_JSON_DESCRIPTION, required: false
  param :enabled, type: :boolean, desc: 'Optional enabled status', required: false

  def execute(scenario_id:, **kwargs)
    ensure_account_administrator!

    scenario = find_scenario!(scenario_id)
    attributes = scenario_update_attributes(scenario: scenario, kwargs: kwargs)
    raise ArgumentError, 'No supported scenario fields were provided' if attributes.blank?

    before_payload = scenario_payload(scenario, include_instruction: true)
    scenario.update!(attributes)

    formatted_payload(
      action: 'update_captain_scenario',
      scenario: scenario_payload(scenario.reload, include_instruction: true),
      previous_scenario: before_payload,
      updated_fields: attributes.keys.map(&:to_s)
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
