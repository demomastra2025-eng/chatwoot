# == Schema Information
#
# Table name: captain_scenarios
#
#  id           :bigint           not null, primary key
#  description  :text
#  enabled      :boolean          default(TRUE), not null
#  instruction  :text
#  title        :string
#  tools        :jsonb
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint           not null
#  assistant_id :bigint           not null
#
# Indexes
#
#  index_captain_scenarios_on_account_id                (account_id)
#  index_captain_scenarios_on_assistant_id              (assistant_id)
#  index_captain_scenarios_on_assistant_id_and_enabled  (assistant_id,enabled)
#  index_captain_scenarios_on_enabled                   (enabled)
#
class Captain::Scenario < ApplicationRecord
  include Concerns::CaptainToolsHelpers
  include Concerns::Agentable

  # OpenAI enforces a 64-char limit on function names. Our handoff tool names
  # prepend "handoff_to_" (11 chars), so we keep a safety margin and cap
  # the full tool name to MAX_HANDOFF_TOOL_NAME_LENGTH (60 chars).
  # Format: "scenario_{id}_{slug}_agent" for persisted records (stable + readable),
  # and "scenario_draft_{slug}_agent" for unsaved records, with slug truncated
  # based on the available length budget.
  HANDOFF_TOOL_PREFIX = Captain::HandoffNaming::TOOL_PREFIX
  HANDOFF_KEY_PREFIX = 'scenario'.freeze
  HANDOFF_KEY_SUFFIX = 'agent'.freeze
  MAX_HANDOFF_TOOL_NAME_LENGTH = Captain::HandoffNaming::MAX_TOOL_NAME_LENGTH
  MAX_AGENT_NAME_LENGTH = MAX_HANDOFF_TOOL_NAME_LENGTH - HANDOFF_TOOL_PREFIX.length
  MAX_HANDOFF_SLUG_LENGTH = 24

  self.table_name = 'captain_scenarios'

  belongs_to :assistant, class_name: 'Captain::Assistant'
  belongs_to :account

  validates :title, presence: true
  validates :description, presence: true, length: { maximum: 2000 }
  validates :instruction, presence: true, length: { maximum: 10_000 }
  validates :assistant_id, presence: true
  validates :account_id, presence: true
  validate :validate_instruction_tools
  validate :validate_instruction_fields

  scope :enabled, -> { where(enabled: true) }

  delegate :temperature, :feature_faq, :feature_memory, :response_guidelines, :guardrails, :system_rule_groups,
           :response_guideline_groups, :guardrail_groups, to: :assistant

  before_save :resolve_tool_references

  def handoff_key
    [handoff_id_key, compact_handoff_slug, HANDOFF_KEY_SUFFIX].compact.join('_')
  end

  def prompt_context
    referenced_field_ids = referenced_field_ids_for_prompt
    available_prompt_tools = prompt_runtime_tools

    {
      title: title,
      global_system_instruction: Llm::Config.global_agent_system_prompt,
      instructions: resolved_instructions,
      assistant_instruction: assistant.system_instruction,
      scenario_system_context_rule: assistant.enabled_system_template_rule_content(
        Captain::Assistant::SYSTEM_TEMPLATE_SLOT_SCENARIO_CONTEXT
      ),
      scenario_role_rule: assistant.enabled_system_template_rule_content(
        Captain::Assistant::SYSTEM_TEMPLATE_SLOT_SCENARIO_ROLE
      ),
      scenario_orchestrator_return_rule: assistant.enabled_system_template_rule_content(
        Captain::Assistant::SYSTEM_TEMPLATE_SLOT_SCENARIO_RETURN
      ),
      scenario_peer_handoffs_rule: assistant.enabled_system_template_rule_content(
        Captain::Assistant::SYSTEM_TEMPLATE_SLOT_SCENARIO_PEER_HANDOFFS
      ),
      scenario_human_handoff_rule: assistant.enabled_system_template_rule_content(
        Captain::Assistant::SYSTEM_TEMPLATE_SLOT_SCENARIO_HUMAN_HANDOFF
      ),
      current_context_rule: assistant.enabled_system_template_rule_content(
        Captain::Assistant::SYSTEM_TEMPLATE_SLOT_CURRENT_CONTEXT
      ),
      reference_glossary_rule: assistant.enabled_system_template_rule_content(
        Captain::Assistant::SYSTEM_TEMPLATE_SLOT_REFERENCE_GLOSSARY
      ),
      runtime_tool_ids: available_prompt_tools.pluck(:id),
      tools: available_prompt_tools,
      assistant_handoff_tool_name: assistant.handoff_tool_name,
      handoff_scenarios: sibling_handoff_scenarios,
      system_rule_groups: system_rule_groups,
      response_guidelines: response_guidelines || [],
      guardrails: guardrails || [],
      response_guideline_groups: response_guideline_groups,
      guardrail_groups: guardrail_groups,
      context_glossary: assistant.context_glossary_groups(referenced_field_ids),
      tool_glossary: assistant.tool_glossary_groups(available_prompt_tools)
    }
  end

  def runtime_tools
    resolved_tools(referenced_tool_ids: prompt_referenced_tool_ids)
  end

  def prompt_runtime_tools
    explicit_tool_ids = prompt_referenced_tool_ids

    resolved_tools(referenced_tool_ids: explicit_tool_ids).select do |tool_definition|
      assistant.prompt_visible_tool?(
        tool_definition,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )
    end
  end

  def prompt_runtime_tool_ids
    prompt_runtime_tools.pluck(:id)
  end

  def runtime_tool_ids
    runtime_tools.pluck(:id)
  end

  def resolve_runtime_prompt_context(context, prompt_state)
    field_ids = referenced_field_ids_for_prompt
    return assistant.resolve_runtime_prompt_context(context, prompt_state) if field_ids.empty?

    runtime_state = Captain::ContextFields::SCOPES.each_with_object({}) do |scope, state|
      scope_value = context[scope] || context[scope.to_s]
      state[scope] = scope_value if scope_value.present?
    end

    effective_prompt_state = assistant.prompt_context_state(
      runtime_state,
      field_ids: field_ids
    )

    assistant.resolve_runtime_prompt_context(
      context,
      effective_prompt_state,
      field_ids: field_ids
    )
  end

  private

  def agent_name
    handoff_key
  end

  def handoff_id_key
    return "#{HANDOFF_KEY_PREFIX}_#{id}" if id.present?

    "#{HANDOFF_KEY_PREFIX}_draft"
  end

  def compact_handoff_slug
    slug = title.to_s.parameterize(separator: '_').presence
    return nil if slug.blank?

    max_slug_length = [MAX_HANDOFF_SLUG_LENGTH, dynamic_slug_max_length].min
    return nil if max_slug_length <= 0

    slug.first(max_slug_length).sub(/_+\z/, '').presence
  end

  def dynamic_slug_max_length
    # handoff_to_#{scenario_<id>_<slug>_agent}
    MAX_AGENT_NAME_LENGTH - handoff_id_key.length - HANDOFF_KEY_SUFFIX.length - 2
  end

  def agent_tools
    runtime_tools.filter_map { |tool| resolve_tool_instance(tool) }
  end

  def resolved_instructions
    render_tool_references(instruction)
  end

  def resolved_tools(referenced_tool_ids: prompt_referenced_tool_ids)
    available_tools = assistant.available_agent_tools
    effective_tool_ids = assistant.scenario_agent_tool_ids(referenced_tool_ids: referenced_tool_ids)
    return [] if effective_tool_ids.empty?

    effective_tool_ids.filter_map do |tool_id|
      next unless effective_tool_ids.include?(tool_id.to_s)

      available_tools.find { |tool| tool[:id] == tool_id }
    end
  end

  def resolve_tool_instance(tool_metadata)
    Captain::ToolCatalog.build_tool(
      tool_metadata,
      assistant: assistant,
      scope_name: Captain::ToolAccess::SCOPE_AGENT
    )
  end

  # Validates that all tool references in the instruction are valid.
  # Parses the instruction for tool references and checks if they exist
  # in the available tools configuration.
  #
  # @return [void]
  # @api private
  # @example Valid instruction
  #   scenario.instruction = "Use [Add Contact Note](tool://add_contact_note) to document"
  #   scenario.valid? # => true
  #
  # @example Invalid instruction
  #   scenario.instruction = "Use [Invalid Tool](tool://invalid_tool) to process"
  #   scenario.valid? # => false
  #   scenario.errors[:instruction] # => ["contains invalid tools: invalid_tool"]
  def validate_instruction_tools
    return if instruction.blank?

    tool_ids = extract_tool_ids_from_text(instruction)
    return if tool_ids.empty?

    all_available_tool_ids = assistant.available_tool_ids
    invalid_tools = tool_ids - all_available_tool_ids

    return unless invalid_tools.any?

    errors.add(:instruction, "contains invalid tools: #{invalid_tools.join(', ')}")
  end

  def validate_instruction_fields
    return if instruction.blank?

    field_ids = Captain::ContextFields.extract_field_ids_from_text(instruction)
    return if field_ids.empty?

    invalid_fields = field_ids - assistant.available_context_field_ids
    return unless invalid_fields.any?

    errors.add(:instruction, "contains invalid fields: #{invalid_fields.join(', ')}")
  end

  # Resolves tool references from the instruction text into the tools field.
  # Parses the instruction for tool references and materializes them as
  # tool IDs stored in the tools JSONB field.
  #
  # @return [void]
  # @api private
  # @example
  #   scenario.instruction = "First [@Add Private Note](tool://add_private_note) then [@Update Priority](tool://update_priority)"
  #   scenario.save!
  #   scenario.tools # => ["add_private_note", "update_priority"]
  #
  #   scenario.instruction = "No tools mentioned here"
  #   scenario.save!
  #   scenario.tools # => nil
  def resolve_tool_references
    return if instruction.blank?

    tool_ids = extract_tool_ids_from_text(instruction)
    self.tools = tool_ids.presence
  end

  def referenced_field_ids_for_prompt
    Captain::ContextFields.extract_field_ids_from_text(prompt_glossary_texts.flatten.compact.join("\n"))
  end

  def sibling_handoff_scenarios
    scenarios = assistant.scenarios.enabled.to_a.reject { |scenario| scenario.id == id }

    scenarios.map do |scenario|
      {
        title: scenario.title,
        key: scenario.handoff_key,
        description: scenario.description
      }
    end
  end

  def prompt_glossary_texts
    [
      instruction,
      assistant.system_instruction,
      assistant.system_rule_contents_for_prompt(template_name: :scenario),
      response_guidelines,
      guardrails
    ]
  end

  def prompt_referenced_tool_ids
    prompt_glossary_texts
      .flatten
      .compact
      .flat_map { |text| extract_tool_ids_from_text(text) }
      .uniq
  end
end
