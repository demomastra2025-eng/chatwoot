class Captain::Tools::Copilot::McpTool < Captain::Tools::BaseTool
  def initialize(assistant, mcp_server, tool_definition, user: nil, conversation: nil, copilot_thread: nil)
    @mcp_server = mcp_server
    @tool_definition = tool_definition.with_indifferent_access
    super(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread)
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

  def execute(**params)
    Captain::Mcp::ExecutionService.new(
      mcp_server: @mcp_server,
      tool_name: @tool_definition[:mcp_tool_name],
      params: params
    ).call
  end

  private

  def tool_definition
    confirmation_required = %w[high custom].include?(@tool_definition[:risk_level].to_s) ||
                            !ActiveModel::Type::Boolean.new.cast(@tool_definition[:idempotent])
    return @tool_definition unless confirmation_required

    @tool_definition.merge(requires_confirmation: true)
  end
end
