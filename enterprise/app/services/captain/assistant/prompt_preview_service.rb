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
        'Scope, feature, integration, safety, and assistant confirmation checks still apply at runtime.'
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

  # The agents of the channels where this agent works (the channel grid), not a stored per-agent list.
  def scenario_previews = peers.map { |agent| scenario_preview(agent) }

  def peers
    @peers ||= assistant.channel_peers
  end

  def allowed_copilot_tools
    assistant.allowed_assistant_tools
  end

  def assistant_layers
    [
      text_layer('global_system_instruction', 'Global system instruction', Llm::Config.global_agent_system_prompt),
      text_layer('instruction', 'System instruction', assistant.system_instruction),
      list_layer(
        'available_runtime_tools',
        'Available runtime tools',
        assistant_runtime_tools.map { |tool| "#{tool[:id]}: #{tool[:description]}" }
      ),
      list_layer(
        'scenario_handoffs',
        'Scenario handoffs',
        peers.map { |agent| "#{agent.name}: #{agent.routing_description}" }
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
      assistant.send(:prompt_glossary_texts_for_template, :assistant)
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
    'Prompt-visible tools come from tool_access plus explicit tool:// references ' \
      'in the editable main prompt; capability tools follow their switches.'
  end

  def scenario_preview(agent)
    compiled_prompt = agent.agent_instructions
    runtime_tools = agent.prompt_runtime_agent_tools
    {
      id: agent.id,
      title: agent.name,
      handoff_key: agent.handoff_target_name,
      prompt_id: "captain_v2.assistant.#{agent.id}",
      template_name: 'assistant',
      prompt_sha256: digest(compiled_prompt),
      compiled_prompt: compiled_prompt,
      used_field_ids: referenced_field_ids_for_texts([agent.system_instruction]) & agent.available_context_field_ids,
      used_tool_ids: runtime_tools.pluck(:id),
      layers: [
        text_layer('instruction', 'Main prompt', agent.system_instruction),
        list_layer('tool_ids', 'Runtime tool IDs', runtime_tools.pluck(:id))
      ]
    }
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

end
