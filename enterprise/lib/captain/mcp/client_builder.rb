class Captain::Mcp::ClientBuilder
  class << self
    def with_client(mcp_server)
      require 'ruby_llm/mcp'

      client = RubyLLM::MCP.client(**mcp_server.client_options)
      client.start
      yield client
    ensure
      client&.stop if client&.alive?
    end
  end
end
