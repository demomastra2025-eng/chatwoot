# frozen_string_literal: true

module Onelink
  module Mcp
    class Server
      PROTOCOL_VERSION = '2025-06-18'
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

      def call(envelope)
        return handle_batch(envelope) if envelope.is_a?(Array)

        handle_request(envelope)
      end

      def handle_batch(envelope)
        return error_response(nil, -32_600, 'Invalid JSON-RPC batch') if envelope.empty?

        responses = envelope.filter_map { |item| handle_request(item) }
        responses.presence
      end

      private

      attr_reader :auth_context, :captain_tool_adapter, :openapi_catalog, :resource_catalog

      def handle_request(envelope)
        request = normalize_request(envelope)
        return handle_notification(request) if request[:id].nil?

        result = dispatch(request[:method], request[:params])
        success_response(request[:id], result)
      rescue JsonRpcError => e
        error_response(envelope_id(envelope), e.code, e.message, e.data)
      rescue StandardError => e
        Rails.logger.warn do
          "#{self.class.name} internal error account=#{auth_context.account.id} user=#{auth_context.user.id}: #{e.class} #{e.message}"
        end
        error_response(envelope_id(envelope), -32_603, 'Internal MCP server error')
      end

      def normalize_request(envelope)
        raise JsonRpcError.new(-32_600, 'Invalid JSON-RPC request') unless envelope.is_a?(Hash)

        normalized = envelope.with_indifferent_access
        raise JsonRpcError.new(-32_600, 'Invalid JSON-RPC version') unless normalized[:jsonrpc] == JSONRPC_VERSION
        raise JsonRpcError.new(-32_600, 'JSON-RPC method is required') if normalized[:method].blank?

        {
          id: normalized[:id],
          method: normalized[:method].to_s,
          params: normalize_params(normalized[:params])
        }
      end

      def normalize_params(params)
        return {} if params.blank?
        raise JsonRpcError.new(-32_602, 'JSON-RPC params must be an object') unless params.is_a?(Hash)

        params.with_indifferent_access
      end

      def envelope_id(envelope)
        envelope.is_a?(Hash) ? envelope.with_indifferent_access[:id] : nil
      end

      def handle_notification(request)
        case request[:method]
        when 'notifications/initialized', 'notifications/cancelled', 'notifications/progress'
          nil
        else
          Rails.logger.info do
            "#{self.class.name} ignored notification method=#{request[:method]} account=#{auth_context.account.id} user=#{auth_context.user.id}"
          end
          nil
        end
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
        requested_protocol = params[:protocolVersion].presence
        {
          protocolVersion: requested_protocol || PROTOCOL_VERSION,
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

        arguments = params[:arguments].is_a?(Hash) ? params[:arguments] : {}
        meta = params[:_meta].is_a?(Hash) ? params[:_meta] : {}

        if name.start_with?(Onelink::Mcp::OpenapiCatalog::TOOL_PREFIX)
          openapi_catalog.call_tool(name: name, arguments: arguments)
        else
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
