class Captain::Tools::HttpTool < Captain::Runtime::Tool
  def initialize(assistant, custom_tool)
    @assistant = assistant
    @custom_tool = custom_tool
    super()
  end

  def active?
    @custom_tool.enabled?
  end

  def metadata
    @custom_tool.to_tool_metadata
  end

  alias tool_definition metadata

  def perform(tool_context, **params)
    ensure_tool_execution_allowed!
    # A local retry key is not proof of remote deduplication or late-write
    # ordering after takeover. Includes legacy AI runs without a fence token.
    runtime_state = tool_context&.state.to_h
    conversation_run = runtime_state[:conversation].to_h[:id].present? || runtime_state[:captain_control_generation].present? ||
                       runtime_state[:captain_response_fence].present?
    if conversation_run && !(%w[GET HEAD].include?(@custom_tool.http_method.to_s.upcase) && @custom_tool.read_only_custom_tool?)
      return Captain::ToolResult.failure_output(
        error: 'Mutating custom HTTP actions require a provider idempotency and reconciliation contract',
        audit: { failure_stage: 'policy', failure_reason: 'unsafe_provider_mutation' }
      )
    end

    Captain::Tools::HttpRequestExecutor.new(
      assistant: @assistant,
      custom_tool: @custom_tool,
      state: tool_context&.state || {}
    ).call(params)
  end

  private

  def ensure_tool_execution_allowed!
    tool_definition = @custom_tool.to_tool_metadata
    return if Captain::ToolPolicy.execution_allowed?(
      tool_definition,
      assistant: @assistant,
      scope_name: Captain::ToolAccess::SCOPE_AGENT
    )

    raise ArgumentError,
          Captain::ToolPolicy.execution_error_message(
            tool_definition,
            assistant: @assistant,
            scope_name: Captain::ToolAccess::SCOPE_AGENT
          )
  end
end
