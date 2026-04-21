# frozen_string_literal: true

require 'digest'

class Captain::Assistant::PromptPreviewService
  PREVIEW_MODE = 'settings_without_live_conversation_context'

  def initialize(assistant:)
    @assistant = assistant
  end

  def preview
    {
      preview_mode: PREVIEW_MODE,
      generated_at: Time.current.iso8601,
      assistant: assistant_preview,
      copilot: copilot_preview,
      scenarios: scenario_previews
    }
  end

  private

  attr_reader :assistant

  def assistant_preview
    compiled_prompt = assistant.agent_instructions

    {
      prompt_id: 'captain_v2.assistant.root',
      template_name: 'assistant',
      prompt_sha256: digest(compiled_prompt),
      compiled_prompt: compiled_prompt,
      notes: [
        'Rendered without live conversation context.',
        effective_runtime_tools_note,
        'High-risk and confirmation policy checks still apply at runtime.'
      ],
      used_field_ids: assistant_used_field_ids,
      used_tool_ids: assistant_used_tool_ids,
      layers: assistant_layers
    }
  end

  def copilot_preview
    compiled_prompt = Captain::Llm::SystemPromptsService.copilot_response_generator(
      assistant.name,
      assistant.system_instruction,
      copilot_tools_summary,
      assistant.config
    )

    {
      prompt_id: 'captain.copilot.response_generator',
      template_name: 'llm/copilot_response_generator',
      prompt_sha256: digest(compiled_prompt),
      compiled_prompt: compiled_prompt,
      notes: [
        'Rendered without conversation-specific copilot context.',
        'Operator permissions can still reduce the effective tool set at runtime.'
      ],
      used_field_ids: [],
      used_tool_ids: allowed_copilot_tools.pluck(:id),
      layers: copilot_layers
    }
  end

  def scenario_previews = assistant.scenarios.enabled.map { |scenario| scenario_preview(scenario) }

  def allowed_copilot_tools
    assistant.allowed_assistant_tools
  end

  def assistant_layers
    [
      text_layer('global_system_instruction', 'Global system instruction', Llm::Config.global_agent_system_prompt),
      text_layer('instruction', 'System instruction', assistant.system_instruction),
      list_layer('system_rules', 'System rules', grouped_rule_values(assistant.system_rule_groups)),
      list_layer('response_guidelines', 'Response guidelines', assistant.response_guidelines),
      list_layer('guardrails', 'Guardrails', assistant.guardrails),
      list_layer(
        'available_runtime_tools',
        'Available runtime tools',
        assistant_runtime_tools.map { |tool| "#{tool[:id]}: #{tool[:description]}" }
      ),
      list_layer(
        'scenario_handoffs',
        'Scenario handoffs',
        assistant.scenarios.enabled.map { |scenario| "#{scenario.title}: #{scenario.description}" }
      )
    ]
  end

  def copilot_layers
    [
      text_layer('assistant_name', 'Assistant name', assistant.name),
      text_layer('global_system_instruction', 'Global system instruction', Llm::Config.global_assistant_system_prompt),
      text_layer('assistant_instruction', 'System instruction', assistant.system_instruction),
      list_layer(
        'available_tools',
        'Available copilot tools',
        allowed_copilot_tools.map { |tool| "#{tool[:id]}: #{tool[:description]}" }
      )
    ]
  end

  def copilot_tools_summary
    Captain::ToolCatalog.summary_for(allowed_copilot_tools)
  end

  def assistant_used_tool_ids
    assistant_runtime_tools.pluck(:id)
  end

  def assistant_used_field_ids
    field_ids = referenced_field_ids_for_texts(
      [
        assistant.system_instruction,
        assistant.system_rule_contents,
        assistant.response_guidelines,
        assistant.guardrails
      ]
    )

    field_ids & assistant.available_context_field_ids
  end

  def assistant_runtime_tools
    if assistant.internal_assistant?
      assistant.allowed_assistant_tools
    else
      assistant.prompt_runtime_agent_tools
    end
  end

  def effective_runtime_tools_note
    'Effective runtime tools come from tool_access plus explicit tool:// references, ' \
      'except capability tools which activate only when their checkbox is enabled.'
  end

  def scenario_preview(scenario)
    compiled_prompt = scenario.agent_instructions
    runtime_tool_ids = scenario.runtime_tool_ids

    {
      id: scenario.id,
      title: scenario.title,
      handoff_key: scenario.handoff_key,
      prompt_id: "captain_v2.scenario.#{scenario.id}",
      template_name: 'scenario',
      prompt_sha256: digest(compiled_prompt),
      compiled_prompt: compiled_prompt,
      used_field_ids: scenario_used_field_ids(scenario),
      used_tool_ids: runtime_tool_ids,
      layers: [
        text_layer('global_system_instruction', 'Global system instruction', Llm::Config.global_agent_system_prompt),
        text_layer('description', 'Description', scenario.description),
        text_layer('instructions', 'Scenario instructions', scenario.instruction),
        list_layer('system_rules', 'System rules', grouped_rule_values(assistant.system_rule_groups)),
        list_layer('response_guidelines', 'Response guidelines', assistant.response_guidelines),
        list_layer('guardrails', 'Guardrails', assistant.guardrails),
        list_layer('tool_ids', 'Runtime tool IDs', runtime_tool_ids)
      ]
    }
  end

  def scenario_used_field_ids(scenario)
    field_ids = referenced_field_ids_for_texts(
      [
        scenario.instruction,
        assistant.system_rule_contents,
        assistant.response_guidelines,
        assistant.guardrails
      ]
    )

    field_ids & assistant.available_context_field_ids
  end

  def referenced_tool_ids_for_texts(texts)
    Array(texts)
      .flatten
      .compact
      .flat_map { |text| assistant.extract_tool_ids_from_text(text) }
      .uniq
  end

  def referenced_field_ids_for_texts(texts)
    Array(texts)
      .flatten
      .compact
      .flat_map { |text| Captain::ContextFields.extract_field_ids_from_text(text) }
      .uniq
  end

  def text_layer(id, title, value)
    {
      id: id,
      title: title,
      kind: 'text',
      enabled: value.present?,
      value: value.to_s
    }
  end

  def list_layer(id, title, values)
    entries = Array(values).map(&:to_s)

    {
      id: id,
      title: title,
      kind: 'list',
      enabled: entries.any?,
      values: entries
    }
  end

  def digest(prompt)
    Digest::SHA256.hexdigest(prompt.to_s)
  end

  def grouped_rule_values(groups)
    Array(groups).flat_map do |group|
      rules = Array(group[:rules]).map(&:to_s)
      next rules if group[:group_name].blank?

      rules.map { |rule| "#{group[:group_name]}: #{rule}" }
    end
  end
end
