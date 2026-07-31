require 'timeout'

class Captain::Mcp::ClientBuilder
  CLOSE_TIMEOUT_SECONDS = 2

  class << self
    def with_client(mcp_server, timeout_seconds: mcp_server.request_timeout)
      require 'ruby_llm/mcp'

      client = RubyLLM::MCP.client(
        **mcp_server.client_options(request_timeout_seconds: timeout_seconds)
      )
      Timeout.timeout(timeout_seconds, Timeout::Error, 'MCP request timed out') do
        client.start
        yield client
      end
    ensure
      stop_client(client, mcp_server)
    end

    private

    def stop_client(client, mcp_server)
      return if client.blank?

      Timeout.timeout(CLOSE_TIMEOUT_SECONDS) { client.stop }
    rescue StandardError => e
      Rails.logger.warn(
        "#{name}: client cleanup failed for mcp_server=#{mcp_server&.id}: #{e.class} #{e.message}"
      )
    end
  end
end
