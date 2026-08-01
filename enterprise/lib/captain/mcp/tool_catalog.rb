require 'socket'
require 'timeout'

class Captain::Mcp::ToolCatalog
  CACHE_TTL = 5.minutes
  FAILURE_CACHE_TTL = 30.seconds
  RUNTIME_CACHE_KEY = :captain_mcp_tool_catalog_runtime_cache
  DISCOVERY_DISABLED_KEY = :captain_mcp_tool_catalog_discovery_disabled
  DISCOVERY_TIMEOUT_SECONDS = 5
  DISCOVERY_MAX_ATTEMPTS = 2
  DISCOVERY_RETRY_DELAY_SECONDS = 0.1
  RETRYABLE_HTTP_STATUSES = [408, 425, 429, 500, 502, 503, 504].freeze

  class << self
    def with_runtime_cache
      previous_cache = Thread.current[RUNTIME_CACHE_KEY]
      Thread.current[RUNTIME_CACHE_KEY] = {}

      yield
    ensure
      Thread.current[RUNTIME_CACHE_KEY] = previous_cache
    end

    def without_discovery
      previous_value = Thread.current[DISCOVERY_DISABLED_KEY]
      Thread.current[DISCOVERY_DISABLED_KEY] = true

      yield
    ensure
      Thread.current[DISCOVERY_DISABLED_KEY] = previous_value
    end

    def available_tools_for(assistant, scope_name)
      return [] if Thread.current[DISCOVERY_DISABLED_KEY]

      runtime_cache = Thread.current[RUNTIME_CACHE_KEY]
      return discover_available_tools(assistant, scope_name) if runtime_cache.nil?

      cache_key = [assistant.account_id, scope_name.to_s]
      runtime_cache.fetch(cache_key) do
        runtime_cache[cache_key] = discover_available_tools(assistant, scope_name)
      end
    end

    private

    def discover_available_tools(assistant, scope_name)
      assistant.account.captain_mcp_servers.enabled.filter_map do |mcp_server|
        next unless mcp_server.normalized_allowed_scopes.include?(scope_name.to_s)

        begin
          DiscoveryService.new(mcp_server).tools.map do |tool_payload|
            mcp_server.to_tool_metadata(tool_payload)
          end
        rescue StandardError => e
          Rails.logger.warn(
            "#{name}: discovery failed for account=#{assistant.account_id} mcp_server=#{mcp_server.id}: #{e.class} #{e.message}"
          )
          nil
        end
      end.flatten
    end
  end

  class DiscoveryService
    def initialize(mcp_server)
      @mcp_server = mcp_server
    end

    def tools(refresh: false)
      if refresh
        tools = fetch_tools_with_retry
        Rails.cache.delete(failure_cache_key)
        return tools
      end
      return [] if Rails.cache.exist?(failure_cache_key)

      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { fetch_tools_with_retry }
    rescue StandardError
      Rails.cache.write(failure_cache_key, true, expires_in: FAILURE_CACHE_TTL)
      raise
    end

    private

    def cache_key
      ['captain', 'mcp_server_tools', @mcp_server.id, @mcp_server.updated_at.to_i].join(':')
    end

    def failure_cache_key
      [cache_key, 'failure'].join(':')
    end

    def fetch_tools_with_retry
      attempts = 0

      begin
        attempts += 1
        fetch_tools
      rescue StandardError => e
        raise unless retryable_discovery_error?(e) && attempts < DISCOVERY_MAX_ATTEMPTS

        sleep(DISCOVERY_RETRY_DELAY_SECONDS)
        retry
      end
    end

    def fetch_tools
      Captain::Mcp::ClientBuilder.with_client(
        @mcp_server,
        timeout_seconds: DISCOVERY_TIMEOUT_SECONDS
      ) do |client|
        client.tools(refresh: true).map do |tool|
          {
            id: tool_id_for(tool.name),
            title: tool.annotations&.title.presence || tool.name.to_s.humanize,
            description: tool.description.to_s,
            risk_level: risk_level_for(tool),
            idempotent: tool.annotations&.idempotent_hint || false,
            mcp_tool_name: tool.name,
            input_schema: tool.params_schema
          }
        end
      end
    end

    def retryable_discovery_error?(error)
      return true if transient_system_error?(error)
      return false unless defined?(RubyLLM::MCP::Errors)
      return true if error.is_a?(RubyLLM::MCP::Errors::TimeoutError)
      return false unless error.is_a?(RubyLLM::MCP::Errors::TransportError)

      RETRYABLE_HTTP_STATUSES.include?(error.code.to_i) || error.message.start_with?('HTTPX Error')
    end

    def transient_system_error?(error)
      [
        Timeout::Error,
        EOFError,
        SocketError,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::ETIMEDOUT
      ].any? { |error_class| error.is_a?(error_class) }
    end

    def tool_id_for(tool_name)
      "mcp__#{@mcp_server.slug}__#{tool_name}"
    end

    def risk_level_for(tool)
      annotations = tool.annotations
      return 'low' if annotations&.read_only_hint
      return 'high' if annotations&.destructive_hint

      'medium'
    end
  end
end
