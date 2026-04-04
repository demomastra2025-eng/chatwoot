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
    Captain::Tools::HttpRequestExecutor.new(
      assistant: @assistant,
      custom_tool: @custom_tool,
      state: tool_context&.state || {}
    ).call(params)
  end
end
