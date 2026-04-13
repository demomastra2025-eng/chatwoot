class Captain::Mcp::ExecutionService
  def initialize(mcp_server:, tool_name:, params:)
    @mcp_server = mcp_server
    @tool_name = tool_name.to_s
    @params = params.to_h.symbolize_keys
  end

  def call
    Captain::Mcp::ClientBuilder.with_client(@mcp_server) do |client|
      tool = client.tool(@tool_name, refresh: true)
      raise ArgumentError, "MCP tool #{@tool_name} is not available" if tool.blank?

      normalize_result(tool.execute(**@params))
    end
  end

  private

  def normalize_result(result)
    if defined?(RubyLLM::Content) && result.is_a?(RubyLLM::Content)
      text = result.text.to_s
      return text if text.present?

      attachment_count = result.attachments&.count.to_i
      return "Tool returned #{attachment_count} attachment(s)." if attachment_count.positive?

      return ''
    end

    return JSON.pretty_generate(result.as_json) if result.is_a?(Hash) || result.is_a?(Array)

    result.to_s
  rescue JSON::GeneratorError
    result.to_s
  end
end
