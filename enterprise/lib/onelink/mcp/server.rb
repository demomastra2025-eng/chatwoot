# frozen_string_literal: true

module Onelink
  module Mcp
    class Server
      PROTOCOL_VERSION = '2025-06-18'
      DEFAULT_PROTOCOL_VERSION = '2025-03-26'
      SUPPORTED_PROTOCOL_VERSIONS = [DEFAULT_PROTOCOL_VERSION, PROTOCOL_VERSION].freeze
      SERVER_NAME = 'onelink-mcp'
      JSONRPC_VERSION = '2.0'

      class JsonRpcError < StandardError
        attr_reader :code, :data

        def initialize(code, message, data = nil)
          @code = code
          @data = data
          super(message)
        end
      end

      def initialize(auth_context:)
        @auth_context = auth_context
        @captain_tool_adapter = Onelink::Mcp::CaptainToolAdapter.new(auth_context: auth_context)
        @openapi_catalog = Onelink::Mcp::OpenapiCatalog.new(auth_context: auth_context)
        @resource_catalog = Onelink::Mcp::ResourceCatalog.new(
          auth_context: auth_context,
          captain_tool_adapter: @captain_tool_adapter,
          openapi_catalog: @openapi_catalog
        )
      end

      def self.negotiate_protocol_version(requested_version)
        return requested_version if SUPPORTED_PROTOCOL_VERSIONS.include?(requested_version)

        PROTOCOL_VERSION
      end

      def call(envelope, transport_version: DEFAULT_PROTOCOL_VERSION)
        if envelope.is_a?(Array)
          return handle_batch(envelope) if transport_version == DEFAULT_PROTOCOL_VERSION

          return error_response(nil, -32_600, 'JSON-RPC batches are not supported for this protocol version')
        end

        protocol_version = protocol_version_for(envelope, transport_version)
        handle_request(envelope, protocol_version: protocol_version)
      end

      def handle_batch(envelope)
        return error_response(nil, -32_600, 'Invalid JSON-RPC batch') if envelope.empty?

        responses = envelope.filter_map { |item| handle_request(item, protocol_version: DEFAULT_PROTOCOL_VERSION) }
        responses.presence
      end

      private

      attr_reader :auth_context, :captain_tool_adapter, :openapi_catalog, :resource_catalog

      def handle_request(envelope, protocol_version: DEFAULT_PROTOCOL_VERSION)
        return nil if response_envelope?(envelope)

        request = normalize_request(envelope)
        return nil if request[:notification]

        result = dispatch(request[:method], request[:params])
        result = adapt_result_for_protocol(request[:method], result, protocol_version)
        success_response(request[:id], result)
      rescue JsonRpcError => e
        error_response(envelope_id(envelope), e.code, e.message, e.data)
      rescue StandardError => e
        Rails.logger.warn("#{self.class.name} internal error: #{e.class}")
        error_response(envelope_id(envelope), -32_603, 'Internal MCP server error')
      end

      def protocol_version_for(envelope, transport_version)
        return transport_version unless valid_initialize_request?(envelope)

        params = envelope.with_indifferent_access[:params]
        requested_version = params.is_a?(Hash) ? params.with_indifferent_access[:protocolVersion] : nil
        self.class.negotiate_protocol_version(requested_version)
      end

      def valid_initialize_request?(envelope)
        return false unless envelope.is_a?(Hash)

        normalized = envelope.with_indifferent_access
        normalized[:jsonrpc] == JSONRPC_VERSION && normalized[:method] == 'initialize' &&
          normalized.key?(:id) && valid_request_id?(normalized[:id]) &&
          !normalized.key?(:result) && !normalized.key?(:error) &&
          (!normalized.key?(:params) || normalized[:params].is_a?(Hash))
      end

      def response_envelope?(envelope)
        return false unless envelope.is_a?(Hash)

        normalized = envelope.with_indifferent_access
        return false unless normalized[:jsonrpc] == JSONRPC_VERSION && !normalized.key?(:method)
        return false unless normalized.key?(:id) && valid_request_id?(normalized[:id])

        has_result = normalized.key?(:result)
        has_error = normalized.key?(:error)
        return false if has_result == has_error

        return true if has_result && normalized[:result].is_a?(Hash)

        error = normalized[:error]
        error.is_a?(Hash) && error.with_indifferent_access[:code].is_a?(Integer) &&
          error.with_indifferent_access[:message].is_a?(String)
      end

      def normalize_request(envelope)
        raise JsonRpcError.new(-32_600, 'Invalid JSON-RPC request') unless envelope.is_a?(Hash)

        normalized = envelope.with_indifferent_access
        raise JsonRpcError.new(-32_600, 'Invalid JSON-RPC version') unless normalized[:jsonrpc] == JSONRPC_VERSION
        unless normalized[:method].is_a?(String) && normalized[:method].present?
          raise JsonRpcError.new(-32_600, 'JSON-RPC method is required')
        end

        if normalized.key?(:result) || normalized.key?(:error)
          raise JsonRpcError.new(-32_600, 'Invalid JSON-RPC request')
        end

        id = normalized[:id]
        raise JsonRpcError.new(-32_600, 'Invalid JSON-RPC id') if normalized.key?(:id) && !valid_request_id?(id)

        {
          id: id,
          notification: !normalized.key?(:id),
          method: normalized[:method].to_s,
          params: normalize_params(normalized[:params], present: normalized.key?(:params))
        }
      end

      def normalize_params(params, present:)
        return {} unless present
        raise JsonRpcError.new(-32_602, 'JSON-RPC params must be an object') unless params.is_a?(Hash)

        params.with_indifferent_access
      end

      def valid_request_id?(id)
        id.is_a?(String) || id.is_a?(Integer)
      end

      def envelope_id(envelope)
        return unless envelope.is_a?(Hash)

        id = envelope.with_indifferent_access[:id]
        valid_request_id?(id) ? id : nil
      end

      def dispatch(method, params)
        case method
        when 'initialize'
          initialize_result(params)
        when 'ping'
          {}
        when 'tools/list'
          tools_list_result
        when 'tools/call'
          tools_call_result(params)
        when 'resources/list'
          resources_list_result
        when 'resources/read'
          resources_read_result(params)
        else
          raise JsonRpcError.new(-32_601, "Unsupported MCP method: #{method}")
        end
      end

      def initialize_result(params)
        {
          protocolVersion: self.class.negotiate_protocol_version(params[:protocolVersion]),
          capabilities: {
            tools: {
              listChanged: false
            },
            resources: {
              subscribe: false,
              listChanged: false
            },
            logging: {}
          },
          serverInfo: {
            name: SERVER_NAME,
            version: server_version
          },
          instructions: 'Use this MCP server only within the authenticated OneLink workspace. Tools and resources are account-scoped and executed with the authenticated user permissions.'
        }
      end

      def server_version
        ENV['GIT_SHA'].presence || ENV['HEROKU_SLUG_COMMIT'].presence || Rails.env
      end

      def tools_list_result
        {
          tools: captain_tool_adapter.tools + openapi_catalog.tools
        }
      end

      def tools_call_result(params)
        name = params[:name].to_s
        raise JsonRpcError.new(-32_602, 'Tool name is required') if name.blank?

        arguments = params[:arguments]
        if params.key?(:arguments) && !arguments.is_a?(Hash)
          raise JsonRpcError.new(-32_602, 'Tool arguments must be an object')
        end

        arguments ||= {}
        meta = params[:_meta].is_a?(Hash) ? params[:_meta] : {}

        if name.start_with?(Onelink::Mcp::OpenapiCatalog::TOOL_PREFIX)
          raise JsonRpcError.new(-32_602, 'Unknown tool') unless openapi_catalog.known_tool?(name)

          openapi_catalog.call_tool(name: name, arguments: arguments)
        else
          raise JsonRpcError.new(-32_602, 'Unknown tool') unless captain_tool_adapter.known_tool?(name)

          captain_tool_adapter.call_tool(name: name, arguments: arguments, meta: meta)
        end
      end

      def resources_list_result
        {
          resources: resource_catalog.list
        }
      end

      def resources_read_result(params)
        uri = params[:uri].to_s
        raise JsonRpcError.new(-32_602, 'Resource uri is required') if uri.blank?

        resource_catalog.read(uri)
      end

      def adapt_result_for_protocol(method, result, protocol_version)
        return result unless protocol_version == DEFAULT_PROTOCOL_VERSION && result.is_a?(Hash)

        case method
        when 'tools/list'
          tools = Array(result[:tools]).map { |tool| tool.is_a?(Hash) ? tool.except(:title, 'title') : tool }
          result.merge(tools: tools)
        when 'tools/call'
          result.except(:structuredContent, 'structuredContent')
        else
          result
        end
      end

      def success_response(id, result)
        {
          jsonrpc: JSONRPC_VERSION,
          id: id,
          result: result || {}
        }
      end

      def error_response(id, code, message, data = nil)
        payload = {
          jsonrpc: JSONRPC_VERSION,
          id: id,
          error: {
            code: code,
            message: message
          }
        }
        payload[:error][:data] = data if data.present?
        payload
      end
    end
  end
end
