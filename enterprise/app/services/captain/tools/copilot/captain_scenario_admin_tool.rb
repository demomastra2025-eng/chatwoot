# frozen_string_literal: true

class Captain::Tools::Copilot::CaptainScenarioAdminTool < Captain::Tools::Copilot::CaptainAssistantAdminTool
  include Concerns::CaptainToolsHelpers

  MANAGED_TOOL_REFERENCES_PREFIX = 'Scenario tool references:'

  private

  def find_scenario!(scenario_id)
    account_scenarios.includes(:assistant).find(scenario_id)
  end

  def find_scenario_assistant!(assistant_id)
    find_captain_assistant!(assistant_id)
  end

  def scenarios_scope(assistant_id: nil)
    scope = account_scenarios.includes(:assistant).order(updated_at: :desc)
    return scope if assistant_id.blank?

    scope.where(assistant_id: find_scenario_assistant!(assistant_id).id)
  end

  def account_scenarios
    Captain::Scenario.where(account_id: account.id)
  end

  def scenario_payload(scenario, include_instruction: false)
    payload = {
      id: scenario.id,
      assistant_id: scenario.assistant_id,
      assistant_name: scenario.assistant&.name,
      title: redacted_value(scenario.title),
      description: redacted_value(scenario.description),
      enabled: scenario.enabled,
      handoff_key: scenario.handoff_key,
      tool_ids: scenario.tools || [],
      created_at: scenario.created_at&.iso8601,
      updated_at: scenario.updated_at&.iso8601
    }
    payload[:instruction] = redacted_value(scenario.instruction) if include_instruction
    payload
  end

  def scenario_update_attributes(scenario:, kwargs:)
    {}.tap do |attributes|
      attributes[:title] = kwargs[:title] if kwargs[:title].present?
      attributes[:description] = kwargs[:description] if kwargs[:description].present?
      attributes[:enabled] = cast_boolean(kwargs[:enabled]) unless kwargs[:enabled].nil?
      attributes[:instruction] = scenario_instruction(scenario, kwargs) if instruction_update?(kwargs)
    end
  end

  def scenario_instruction(scenario, kwargs)
    base_instruction = kwargs.key?(:instruction) ? kwargs[:instruction].to_s : scenario.instruction.to_s
    apply_tool_references(base_instruction, scenario.assistant, kwargs[:tool_ids_json])
  end

  def instruction_update?(kwargs)
    kwargs.key?(:instruction) || kwargs[:tool_ids_json].present?
  end

  def apply_tool_references(instruction, assistant, tool_ids_json)
    if tool_ids_json.blank?
      validate_no_tool_references!(instruction)
      return instruction
    end

    validate_no_unmanaged_tool_references!(instruction)
    normalized_tool_ids = parse_tool_ids(tool_ids_json)
    validate_scenario_tool_ids!(assistant, normalized_tool_ids)
    append_managed_tool_references(instruction, normalized_tool_ids)
  end

  def parse_tool_ids(tool_ids_json)
    tool_ids = parse_json_array(tool_ids_json, field_name: 'tool_ids_json', default: [])
    raise ArgumentError, 'tool_ids_json must contain tool IDs' unless tool_ids.all? { |tool_id| tool_id.is_a?(String) || tool_id.is_a?(Symbol) }

    tool_ids.map(&:to_s).map(&:strip).reject(&:blank?).uniq
  end

  def append_managed_tool_references(instruction, tool_ids)
    sanitized_instruction = remove_managed_tool_references(instruction.to_s).strip
    return sanitized_instruction if tool_ids.empty?

    references = tool_ids.map { |tool_id| "[#{tool_title(tool_id)}](tool://#{tool_id})" }.join(', ')
    [sanitized_instruction, "#{MANAGED_TOOL_REFERENCES_PREFIX} #{references}"].reject(&:blank?).join("\n\n")
  end

  def remove_managed_tool_references(instruction)
    instruction.to_s.lines.reject { |line| line.strip.start_with?(MANAGED_TOOL_REFERENCES_PREFIX) }.join
  end

  def validate_scenario_tool_ids!(assistant, tool_ids)
    invalid_tool_ids = tool_ids - assistant.available_tool_ids
    return if invalid_tool_ids.empty?

    raise ArgumentError, "tool_ids_json contains invalid tools: #{invalid_tool_ids.join(', ')}"
  end

  def validate_no_unmanaged_tool_references!(instruction)
    unmanaged_tool_ids = extract_any_tool_reference_ids(remove_managed_tool_references(instruction))
    return if unmanaged_tool_ids.empty?

    raise ArgumentError, 'Use tool_ids_json to manage scenario tool references'
  end

  def validate_no_tool_references!(instruction)
    tool_ids = extract_any_tool_reference_ids(instruction)
    return if tool_ids.empty?

    raise ArgumentError, 'Use tool_ids_json to manage scenario tool references'
  end

  def extract_any_tool_reference_ids(text)
    markdown_tool_ids = extract_tool_ids_from_text(text)
    plain_tool_ids = text.to_s.scan(%r{tool://([A-Za-z0-9_\-/]+)}).flatten.map { |tool_id| normalize_tool_id(tool_id) }
    (markdown_tool_ids + plain_tool_ids).uniq
  end

  def tool_title(tool_id)
    Captain::ToolRegistry.definition_for(tool_id)&.title || tool_id
  end
end
