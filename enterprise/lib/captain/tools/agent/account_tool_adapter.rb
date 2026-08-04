class Captain::Tools::Agent::AccountToolAdapter < Captain::Runtime::Tool
  include Captain::ToolResultOutput

  def initialize(assistant, tool_id:)
    @assistant = assistant
    @tool_id = tool_id.to_s
    super()
  end

  def name
    tool_id
  end

  def description
    definition&.description || delegate_class.description
  end

  def parameters
    delegate_class.parameters
  end

  def params_schema
    @params_schema ||= schema_delegate.params_schema
  end

  def provider_params
    delegate_class.provider_params
  end

  def active?
    true
  end

  def normalize_runtime_arguments(arguments, context:)
    return arguments unless schema_delegate.respond_to?(:normalize_runtime_arguments)

    schema_delegate.normalize_runtime_arguments(arguments, context: context)
  end

  def execute(tool_context, **params)
    ensure_tool_execution_allowed!
    result = invoke_delegate(tool_context, params)
    audit_tool_execution(arguments: params, result: result, runtime_context: runtime_context(tool_context))
    result
  rescue StandardError => e
    audit_tool_execution(arguments: params, error: e, runtime_context: runtime_context(tool_context))
    raise
  end

  private

  attr_reader :assistant, :tool_id

  def definition
    @definition ||= Captain::ToolRegistry.definition_for(tool_id)
  end

  def tool_definition
    definition&.to_h || { id: tool_id, title: tool_id.humanize, custom: false }
  end

  def ensure_tool_execution_allowed!
    return if Captain::ToolPolicy.execution_allowed?(
      tool_definition,
      assistant: assistant,
      scope_name: Captain::ToolAccess::SCOPE_AGENT
    )

    raise ArgumentError,
          Captain::ToolPolicy.execution_error_message(
            tool_definition,
            assistant: assistant,
            scope_name: Captain::ToolAccess::SCOPE_AGENT
          )
  end

  def delegate_class
    definition&.assistant_tool_class || raise(ArgumentError, "No delegate tool class registered for #{tool_id}")
  end

  def schema_delegate
    @schema_delegate ||= delegate_class.new(assistant, user: assistant)
  end

  def invoke_delegate(tool_context, params)
    delegate = delegate_class.new(
      assistant,
      user: assistant,
      conversation: current_conversation(tool_context)
    )
    execute_method = delegate.method(:execute)
    execute_method = execute_method.super_method if execute_method.owner == Captain::Tools::Instrumentation && execute_method.super_method
    execute_method.call(**params)
  end

  def current_conversation(tool_context)
    conversation_id = state_value(tool_context, :conversation, :id)
    return if conversation_id.blank?

    assistant.account.conversations.find_by(id: conversation_id)
  end

  def state_value(tool_context, group_key, field_key)
    state = tool_context&.state || {}
    group = state[group_key] || state[group_key.to_s] || {}
    group[field_key] || group[field_key.to_s]
  end

  def audit_tool_execution(arguments:, result: nil, error: nil, runtime_context: {})
    Captain::ToolExecutionAuditService.record(
      assistant: assistant,
      scope_name: Captain::ToolAccess::SCOPE_AGENT,
      tool_definition: tool_definition,
      arguments: arguments,
      result: result,
      error: error,
      runtime_context: runtime_context
    )
  end

  def runtime_context(tool_context)
    {
      conversation_id: state_value(tool_context, :conversation, :id),
      conversation_display_id: state_value(tool_context, :conversation, :display_id),
      source: state_root_value(tool_context, :source),
      current_agent: context_value(tool_context, :current_agent)
    }.compact
  end

  def state_root_value(tool_context, key)
    state = tool_context&.state || {}
    state[key] || state[key.to_s]
  end

  def context_value(tool_context, key)
    context = tool_context&.context || {}
    context[key] || context[key.to_s]
  end
end
