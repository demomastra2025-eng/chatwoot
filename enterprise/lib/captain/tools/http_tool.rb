class Captain::Tools::HttpTool < Captain::Runtime::Tool
  def initialize(assistant, custom_tool)
    @assistant = assistant
    @custom_tool = custom_tool
    super()
  end

  def active?
    @custom_tool.enabled?
  end

  def perform(tool_context, **params)
    ensure_tool_execution_allowed!
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
