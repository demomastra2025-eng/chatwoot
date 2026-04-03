class Captain::Tools::Copilot::CustomHttpTool < Captain::Tools::BaseTool
  CONTACT_INBOX_STATE_ATTRIBUTES = %i[id hmac_verified].freeze

  def initialize(assistant, custom_tool, user: nil, conversation: nil)
    @custom_tool = custom_tool
    super(assistant, user: user, conversation: conversation)
  end

  def name
    @custom_tool.slug
  end

  def description
    @custom_tool.description
  end

  def parameters
    @parameters ||= @custom_tool.agent_parameter_definitions.each_with_object({}) do |param_definition, memo|
      memo[param_definition['name'].to_sym] = RubyLLM::Parameter.new(
        param_definition['name'].to_sym,
        type: param_definition['type'],
        desc: param_definition['description'],
        required: param_definition.fetch('required', false)
      )
    end
  end

  def execute(**params)
    Captain::Tools::HttpRequestExecutor.new(
      assistant: assistant,
      custom_tool: @custom_tool,
      state: build_state
    ).call(params)
  end

  def active?
    @custom_tool.enabled?
  end

  private

  def tool_definition
    @custom_tool.to_tool_metadata
  end

  def build_state
    state = {
      account_id: assistant.account_id,
      assistant_id: assistant.id
    }
    return state unless @conversation

    state[:conversation] = @conversation.attributes.symbolize_keys.slice(*Captain::ContextFields::CONVERSATION_STATE_ATTRIBUTES)
    state[:contact] = @conversation.contact&.attributes&.symbolize_keys&.slice(*Captain::ContextFields::CONTACT_STATE_ATTRIBUTES) if @conversation.contact
    state[:deal] = Captain::ContextFields.deal_state_for(account: assistant.account, conversation: @conversation)
    state[:task] = Captain::ContextFields.task_state_for(account: assistant.account, conversation: @conversation)
    state[:appointment] = Captain::ContextFields.appointment_state_for(account: assistant.account, conversation: @conversation)
    state[:contact_inbox] = @conversation.contact_inbox&.attributes&.symbolize_keys&.slice(*CONTACT_INBOX_STATE_ATTRIBUTES) if @conversation.contact_inbox
    state.compact!
    state[:prompt_context] = assistant.prompt_context_state(state)
    state
  end
end
