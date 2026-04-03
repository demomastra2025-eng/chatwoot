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
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#
# Indexes
#
#  index_captain_assistants_on_account_id  (account_id)
#
class Captain::Assistant < ApplicationRecord
  include Avatarable
  include Concerns::CaptainToolsHelpers
  include Concerns::Agentable

  self.table_name = 'captain_assistants'

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

  store_accessor :config, :temperature, :feature_faq, :feature_memory, :product_name,
                 :message_collapse_window_seconds, :history_message_limit,
                 :auto_reply_on_last_incoming, :context_access, :tool_access
  store_accessor :config, :feature_contact_attributes

  before_validation :initialize_context_access_config, on: :create

  validates :name, presence: true
  validates :description, presence: true
  validates :account_id, presence: true
  validates :message_collapse_window_seconds,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_blank: true
  validates :history_message_limit,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_blank: true

  scope :ordered, -> { order(created_at: :desc) }

  scope :for_account, ->(account_id) { where(account_id: account_id) }

  def available_name
    name
  end

  def available_agent_tools
    tools = self.class.built_in_agent_tools.map(&:dup)

    custom_tools = account.captain_custom_tools.enabled.map(&:to_tool_metadata)
    tools.concat(custom_tools)

    tools
  end

  def available_tool_ids
    available_agent_tools.pluck(:id)
  end

  def available_assistant_tools
    Captain::Copilot::ToolCatalog.tools_for(self)
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
    allowed_context_fields.map { |field| field[:id] }
  end

  def normalized_context_access
    Captain::ContextFields.normalized_access_for(self, available_context_fields)
  end

  def normalized_tool_access
    Captain::ToolAccess.normalized_access_for(self)
  end

  def allowed_agent_tool_ids
    Captain::ToolAccess.allowed_tool_ids_for(
      self,
      Captain::ToolAccess::SCOPE_AGENT,
      fallback_ids: available_tool_ids
    )
  end

  def direct_agent_tool_ids
    Captain::ToolAccess.allowed_tool_ids_for(
      self,
      Captain::ToolAccess::SCOPE_AGENT,
      fallback_ids: Captain::ToolAccess::DEFAULT_AGENT_TOOL_IDS
    )
  end

  def allowed_agent_tools
    available_agent_tools.select { |tool| allowed_agent_tool_ids.include?(tool[:id]) }
  end

  def allowed_assistant_tool_ids
    Captain::ToolAccess.allowed_tool_ids_for(
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

  def history_message_limit_value
    config_integer_value('history_message_limit')
  end

  def auto_reply_on_last_incoming_enabled?
    config['auto_reply_on_last_incoming'] == true
  end

  private

  def agent_name
    name.parameterize(separator: '_')
  end

  def agent_tools
    available_agent_tools.filter_map do |tool_metadata|
      next unless direct_agent_tool_ids.include?(tool_metadata[:id])
      next unless Captain::ToolPolicy.runtime_allowed?(
        tool_metadata,
        assistant: self,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      resolve_agent_tool_instance(tool_metadata)
    end
  end

  def prompt_context
    {
      name: name,
      description: description,
      product_name: config['product_name'] || 'this product',
      scenarios: scenarios.enabled.map do |scenario|
        {
          title: scenario.title,
          key: scenario.handoff_key,
          description: scenario.description
        }
      end,
      response_guidelines: response_guidelines || [],
      guardrails: guardrails || []
    }
  end

  def resolve_runtime_value(value, prompt_state)
    allowed_fields = allowed_context_fields

    case value
    when String
      Captain::ContextFields.render_references(value, prompt_state: prompt_state, allowed_fields: allowed_fields)
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

  def resolve_agent_tool_instance(tool_metadata)
    if tool_metadata[:custom]
      account.captain_custom_tools.enabled.find_by(slug: tool_metadata[:id])&.tool(self)
    else
      self.class.resolve_tool_class(tool_metadata[:id])&.new(self)
    end
  end
end
