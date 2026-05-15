class Captain::Tools::Copilot::CustomHttpTool < Captain::Tools::BaseTool
  CONTACT_INBOX_STATE_ATTRIBUTES = %i[id hmac_verified].freeze

  def initialize(assistant, custom_tool, user: nil, conversation: nil, copilot_thread: nil)
    @custom_tool = custom_tool
    super(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread)
  end

  def name
    @custom_tool.slug
  end

  def description
    @custom_tool.description
  end

  def parameters
    @parameters ||= @custom_tool.runtime_parameters(Captain::ToolAccess::SCOPE_ASSISTANT)
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
    @custom_tool.to_tool_metadata.merge(requires_confirmation: true)
  end

  def build_state
    state = {
      account_id: assistant.account_id,
      assistant_id: assistant.id
    }
    return state unless @conversation

    state[:conversation] = @conversation.attributes.symbolize_keys.slice(*Captain::ContextFields::CONVERSATION_STATE_ATTRIBUTES)
    if @conversation.contact
      state[:contact] =
        @conversation.contact&.attributes&.symbolize_keys&.slice(*Captain::ContextFields::CONTACT_STATE_ATTRIBUTES)
    end
    state[:deal] = Captain::ContextFields.deal_state_for(account: assistant.account, conversation: @conversation)
    state[:task] = Captain::ContextFields.task_state_for(account: assistant.account, conversation: @conversation)
    state[:appointment] = Captain::ContextFields.appointment_state_for(account: assistant.account, conversation: @conversation)
    if @conversation.contact_inbox
      state[:contact_inbox] =
        @conversation.contact_inbox&.attributes&.symbolize_keys&.slice(*CONTACT_INBOX_STATE_ATTRIBUTES)
    end
    state.compact!
    state[:prompt_context] = assistant.prompt_context_state(state)
    state
  end
end
