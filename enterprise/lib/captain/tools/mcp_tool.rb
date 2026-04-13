class Captain::Tools::McpTool < Captain::Tools::BasePublicTool
  def initialize(assistant, mcp_server, tool_definition)
    super(assistant)
    @mcp_server = mcp_server
    @tool_definition = tool_definition.with_indifferent_access
  end

  def name
    @tool_definition[:id]
  end

  def description
    @tool_definition[:description]
  end

  def parameters
    @parameters ||= Captain::Mcp::ParameterBuilder.from_schema(@tool_definition[:input_schema])
  end

  def params_schema
    @tool_definition[:input_schema]
  end

  def active?
    @mcp_server.enabled?
  end

  def perform(_tool_context, **params)
    Captain::Mcp::ExecutionService.new(
      mcp_server: @mcp_server,
      tool_name: @tool_definition[:mcp_tool_name],
      params: params
    ).call
  end

  private

  def tool_definition
    @tool_definition
  end
end
