# == Schema Information
#
# Table name: captain_assistants
#
#  id                  :bigint           not null, primary key
#  config              :jsonb            not null
#  description         :string
#  guardrails          :jsonb
#  name                :string           not null
#  response_guidelines :jsonb
#  usage_mode          :string           default("external_agent"), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#
# Indexes
#
#  index_captain_assistants_on_account_id  (account_id)
#  index_captain_assistants_on_usage_mode  (usage_mode)
#
class Captain::Assistant < ApplicationRecord
  include Avatarable
  include Concerns::CaptainToolsHelpers
  include Concerns::Agentable

  self.table_name = 'captain_assistants'
  INTERNAL_ASSISTANT_INBOX_ERROR = 'Internal assistants cannot be connected to channels. Disconnect connected channels first.'.freeze

  belongs_to :account
  has_many :documents, class_name: 'Captain::Document', dependent: :destroy_async
  has_many :responses, class_name: 'Captain::AssistantResponse', dependent: :destroy_async
  has_many :captain_inboxes,
           class_name: 'CaptainInbox',
           foreign_key: :captain_assistant_id,
           dependent: :destroy_async
  has_many :inboxes,
           through: :captain_inboxes
  has_many :messages, as: :sender, dependent: :nullify
  has_many :copilot_threads, dependent: :destroy_async
  has_many :scenarios, class_name: 'Captain::Scenario', dependent: :destroy_async

  store_accessor :config, :temperature, :feature_faq, :feature_memory,
                 :message_collapse_window_seconds, :history_message_limit,
                 :auto_reply_on_last_incoming, :context_access, :tool_access

  before_validation :initialize_context_access_config, on: :create
  before_validation :ensure_usage_mode
  before_validation :normalize_instruction_description

  validates :name, presence: true
  validates :description, presence: true
  validates :account_id, presence: true
  validates :usage_mode, presence: true, inclusion: { in: %w[external_agent internal_assistant] }
  validates :message_collapse_window_seconds,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_blank: true
  validates :history_message_limit,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_blank: true
  validate :internal_assistant_cannot_have_connected_inboxes
  validate :validate_instruction_tools
  validate :validate_instruction_fields
  validate :validate_response_guideline_tools
  validate :validate_response_guideline_fields
  validate :validate_guardrail_tools
  validate :validate_guardrail_fields

  scope :ordered, -> { order(created_at: :desc) }

  scope :for_account, ->(account_id) { where(account_id: account_id) }

  enum :usage_mode, {
    external_agent: 'external_agent',
    internal_assistant: 'internal_assistant'
  }, validate: false

  def available_name
    name
  end

  def available_agent_tools
    Captain::ToolCatalog.available_tools_for(self, Captain::ToolAccess::SCOPE_AGENT)
  end

  def available_tool_ids
    available_agent_tools.pluck(:id)
  end

  def available_assistant_tools
    Captain::ToolCatalog.available_tools_for(self, Captain::ToolAccess::SCOPE_ASSISTANT)
  end

  def available_assistant_tool_ids
    available_assistant_tools.pluck(:id)
  end

  def available_context_fields
    Captain::ContextFields.definitions_for(account)
  end

  def allowed_context_fields
    Captain::ContextFields.allowed_definitions_for(self)
  end

  def allowed_context_field_ids
    allowed_context_fields.pluck(:id)
  end

  def context_glossary_groups(field_ids = nil)
    definitions = glossary_context_definitions(field_ids)
    return [] if definitions.empty?

    Captain::ContextFields.glossary_groups_for_definitions(definitions)
  end

  def normalized_context_access
    Captain::ContextFields.normalized_access_for(self, available_context_fields)
  end

  def normalized_tool_access
    Captain::ToolAccess.normalized_access_for(self)
  end

  def allowed_agent_tool_ids
    Captain::ToolCatalog.allowed_tool_ids_for(self, Captain::ToolAccess::SCOPE_AGENT, fallback_ids: available_tool_ids)
  end

  def direct_agent_tool_ids
    Captain::ToolCatalog.allowed_tool_ids_for(
      self,
      Captain::ToolAccess::SCOPE_AGENT,
      fallback_ids: Captain::ToolAccess::DEFAULT_AGENT_TOOL_IDS
    )
  end

  def allowed_agent_tools
    Captain::ToolCatalog.allowed_tools_for(
      self,
      Captain::ToolAccess::SCOPE_AGENT,
      fallback_ids: available_tool_ids
    )
  end

  def direct_agent_tools
    allowed_agent_tools.select { |tool| direct_agent_tool_ids.include?(tool[:id]) }
  end

  def tool_glossary_groups(tools = direct_agent_tools, tool_ids = nil)
    glossary_tools = glossary_tool_definitions(tools, tool_ids)
    return [] if glossary_tools.empty?

    glossary_tools
      .uniq { |tool| tool[:id] }
      .group_by { |tool| tool[:group_name].presence || 'Tools' }
      .map do |group_name, grouped_tools|
        {
          group_name: group_name,
          entries: grouped_tools.map do |tool|
            {
              id: tool[:id].to_s,
              title: tool[:title].to_s,
              description: tool[:description].to_s
            }
          end
        }
      end
  end

  def allowed_assistant_tool_ids
    Captain::ToolCatalog.allowed_tool_ids_for(
      self,
      Captain::ToolAccess::SCOPE_ASSISTANT,
      fallback_ids: available_assistant_tool_ids
    )
  end

  def prompt_context_state(runtime_state = {})
    Captain::ContextFields.prompt_state_for(assistant: self, runtime_state: runtime_state)
  end

  def render_runtime_text(text, conversation: nil)
    runtime_state = runtime_state_for(conversation)
    prompt_state = prompt_context_state(runtime_state)

    resolve_runtime_value(text, prompt_state)
  end

  def resolve_runtime_prompt_context(context, prompt_state)
    resolve_runtime_value(context, prompt_state)
  end

  def push_event_data
    {
      id: id,
      name: name,
      avatar_url: avatar_url,
      description: description,
      created_at: created_at,
      type: 'captain_assistant'
    }
  end

  def webhook_data
    {
      id: id,
      name: name,
      avatar_url: avatar_url,
      description: description,
      created_at: created_at,
      type: 'captain_assistant'
    }
  end

  def message_collapse_window_seconds_value
    config_integer_value('message_collapse_window_seconds')
  end

  def system_instruction
    description.to_s.strip
  end

  def history_message_limit_value
    config_integer_value('history_message_limit')
  end

  def auto_reply_on_last_incoming_enabled?
    config['auto_reply_on_last_incoming'] == true
  end

  private

  def ensure_usage_mode
    self.usage_mode = usage_mode.presence || 'external_agent'
  end

  def normalize_instruction_description
    self.description = description.to_s.strip
    remove_legacy_config_keys
  end

  def agent_name
    name.parameterize(separator: '_')
  end

  def agent_tools
    Captain::ToolCatalog.allowed_tools_for(
      self,
      Captain::ToolAccess::SCOPE_AGENT,
      fallback_ids: Captain::ToolAccess::DEFAULT_AGENT_TOOL_IDS
    ).filter_map do |tool_metadata|
      next unless Captain::ToolPolicy.runtime_allowed?(
        tool_metadata,
        assistant: self,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      Captain::ToolCatalog.build_tool(
        tool_metadata,
        assistant: self,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )
    end
  end

  def prompt_context
    referenced_field_ids = referenced_field_ids_for_texts(prompt_glossary_texts)
    referenced_tool_ids = referenced_tool_ids_for_texts(prompt_glossary_texts)

    {
      name: name,
      global_system_instruction: Llm::Config.global_agent_system_prompt,
      instruction: system_instruction,
      scenarios: scenarios.enabled.map do |scenario|
        {
          title: scenario.title,
          key: scenario.handoff_key,
          description: scenario.description
        }
      end,
      response_guidelines: response_guidelines || [],
      guardrails: guardrails || [],
      context_glossary: context_glossary_groups(referenced_field_ids),
      tool_glossary: tool_glossary_groups(direct_agent_tools, referenced_tool_ids)
    }
  end

  def remove_legacy_config_keys
    return unless config.is_a?(Hash)

    config.delete('instructions')
    config.delete('copilot_instructions')
    config.delete('feature_contact_attributes')
  end

  def resolve_runtime_value(value, prompt_state)
    allowed_fields = allowed_context_fields

    case value
    when String
      text_with_tools = render_tool_references(value)
      Captain::ContextFields.render_references(text_with_tools, prompt_state: prompt_state, allowed_fields: allowed_fields)
    when Array
      value.map { |item| resolve_runtime_value(item, prompt_state) }
    when Hash
      value.transform_values { |item| resolve_runtime_value(item, prompt_state) }
    else
      value
    end
  end

  def runtime_state_for(conversation)
    return {} unless conversation

    runtime_state = {
      conversation: conversation.attributes.symbolize_keys.slice(*Captain::ContextFields::CONVERSATION_STATE_ATTRIBUTES),
      contact: conversation.contact&.attributes&.symbolize_keys&.slice(*Captain::ContextFields::CONTACT_STATE_ATTRIBUTES)
    }.compact

    deal_state = Captain::ContextFields.deal_state_for(account: account, conversation: conversation)
    runtime_state[:deal] = deal_state if deal_state.present?

    task_state = Captain::ContextFields.task_state_for(account: account, conversation: conversation)
    runtime_state[:task] = task_state if task_state.present?

    appointment_state = Captain::ContextFields.appointment_state_for(account: account, conversation: conversation)
    runtime_state[:appointment] = appointment_state if appointment_state.present?
    runtime_state
  end

  def config_integer_value(key)
    value = config[key]
    value.present? ? value.to_i : 0
  end

  def initialize_context_access_config
    self.config = (config || {}).deep_stringify_keys
    config['context_access'] ||= {}
  end

  def internal_assistant_cannot_have_connected_inboxes
    return unless internal_assistant?
    return unless captain_inboxes.exists?

    errors.add(:usage_mode, INTERNAL_ASSISTANT_INBOX_ERROR)
  end

  def validate_instruction_tools
    add_invalid_tool_error(:description, invalid_tool_ids_for_texts([description]))
  end

  def validate_instruction_fields
    add_invalid_field_error(:description, invalid_field_ids_for_texts([description]))
  end

  def validate_response_guideline_tools
    add_invalid_tool_error(:response_guidelines, invalid_tool_ids_for_texts(response_guidelines))
  end

  def validate_response_guideline_fields
    add_invalid_field_error(:response_guidelines, invalid_field_ids_for_texts(response_guidelines))
  end

  def validate_guardrail_tools
    add_invalid_tool_error(:guardrails, invalid_tool_ids_for_texts(guardrails))
  end

  def validate_guardrail_fields
    add_invalid_field_error(:guardrails, invalid_field_ids_for_texts(guardrails))
  end

  def invalid_tool_ids_for_texts(texts)
    tool_ids = referenced_tool_ids_for_texts(texts)
    return [] if tool_ids.empty?

    tool_ids - allowed_agent_tool_ids
  end

  def invalid_field_ids_for_texts(texts)
    field_ids = referenced_field_ids_for_texts(texts)
    return [] if field_ids.empty?

    field_ids - allowed_context_field_ids
  end

  def prompt_glossary_texts
    [system_instruction, response_guidelines, guardrails]
  end

  def referenced_tool_ids_for_texts(texts)
    Array(texts).flatten.compact.flat_map { |text| extract_tool_ids_from_text(text) }.uniq
  end

  def referenced_field_ids_for_texts(texts)
    Array(texts).flatten.compact.flat_map { |text| Captain::ContextFields.extract_field_ids_from_text(text) }.uniq
  end

  def glossary_context_definitions(field_ids)
    definitions = allowed_context_fields
    return definitions if field_ids.nil?

    normalized_field_ids = Array(field_ids).map(&:to_s)
    definitions.select { |field| normalized_field_ids.include?(field[:id].to_s) }
  end

  def glossary_tool_definitions(tools, tool_ids)
    definitions = Array(tools)
    return definitions if tool_ids.nil?

    normalized_tool_ids = Array(tool_ids).map(&:to_s)
    definitions.select { |tool| normalized_tool_ids.include?(tool[:id].to_s) }
  end

  def add_invalid_tool_error(field, invalid_tool_ids)
    return if invalid_tool_ids.empty?

    errors.add(field, "contains invalid tools: #{invalid_tool_ids.join(', ')}")
  end

  def add_invalid_field_error(field, invalid_field_ids)
    return if invalid_field_ids.empty?

    errors.add(field, "contains invalid fields: #{invalid_field_ids.join(', ')}")
  end
end
