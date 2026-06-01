# frozen_string_literal: true

require 'cgi'
require 'rack/mock'

module Onelink
  module Mcp
    class OpenapiCatalog
      SWAGGER_PATH = Rails.root.join('swagger/swagger.json')
      ACCOUNT_API_PREFIX = '/api/v1/accounts/{account_id}'
      HTTP_METHODS = %w[get post patch put delete].freeze
      READ_METHOD = 'GET'
      TOOL_PREFIX = 'api__'
      REQUEST_BODY_ARGUMENT = 'body'
      CONFIRM_ARGUMENT = '_confirm'
      IDEMPOTENCY_ARGUMENT = '_idempotency_key'
      RESERVED_ARGUMENT_KEYS = [REQUEST_BODY_ARGUMENT, CONFIRM_ARGUMENT, IDEMPOTENCY_ARGUMENT].freeze
      HIGH_RISK_TERMS = %w[
        delete destroy cancel reset archive approve restart resume bulk payment
        campaign webhook inbox agent team automation macro sla custom_role touch
        message
      ].freeze
      HIGH_RISK_PATTERN = /(#{HIGH_RISK_TERMS.join('|')})/i

      def initialize(auth_context:)
        @auth_context = auth_context
      end

      def tools
        operations.filter_map do |operation|
          next unless auth_context.mcp_access_policy.allows_openapi_operation?(operation)

          tool_for(operation)
        end
      end

      def catalog_entries
        operations.map { |operation| catalog_entry(operation) }
      end

      def call_tool(name:, arguments:)
        operation = operations.find { |item| tool_name_for(item).to_s == name.to_s }
        return error_tool_response("OpenAPI tool '#{name}' is not available") if operation.blank?
        unless auth_context.mcp_access_policy.allows_openapi_operation?(operation)
          return error_tool_response("OpenAPI tool '#{name}' is disabled by this workspace MCP access policy")
        end

        execution_arguments = arguments.respond_to?(:to_h) ? arguments.to_h : {}
        if operation[:requires_confirmation] && !auth_context.mcp_access_policy.mutation_confirmed?(execution_arguments)
          return error_tool_response("OpenAPI mutation tool '#{name}' requires #{CONFIRM_ARGUMENT}: true")
        end

        result = dispatch_request(operation, execution_arguments)
        audit_openapi_call(name: name, operation: operation, arguments: execution_arguments, result: result)
        result
      rescue StandardError => e
        audit_openapi_call(name: name, operation: operation, arguments: execution_arguments || {}, error: e)
        Rails.logger.warn do
          "#{self.class.name} failed account=#{auth_context.account.id} user=#{auth_context.user.id} tool=#{name}: #{e.class} #{e.message}"
        end
        error_tool_response(redact_value("#{e.class.name}: #{e.message}").to_s)
      end

      private

      attr_reader :auth_context

      def operations
        @operations ||= begin
          paths = swagger.fetch('paths', {})
          paths.each_with_object([]) do |(path, path_payload), result|
            next unless path.start_with?(ACCOUNT_API_PREFIX)
            next unless path_payload.is_a?(Hash)

            HTTP_METHODS.each do |method|
              operation_payload = path_payload[method]
              next unless operation_payload.is_a?(Hash)

              result << normalize_operation(path, path_payload, method, operation_payload)
            end
          end.sort_by { |operation| [operation[:source].to_s, operation[:tag].to_s, operation[:name].to_s] }
        end
      end

      def swagger
        @swagger ||= JSON.parse(File.read(SWAGGER_PATH))
      rescue Errno::ENOENT, JSON::ParserError => e
        Rails.logger.warn("#{self.class.name} could not load #{SWAGGER_PATH}: #{e.class} #{e.message}")
        {}
      end

      def normalize_operation(path, path_payload, method, operation_payload)
        parameters = Array(path_payload['parameters']) + Array(operation_payload['parameters'])
        operation_id = operation_payload['operationId'].presence || "#{method.upcase} #{path}"
        tag = Array(operation_payload['tags']).first.presence || 'API'
        risk_level = risk_level_for(method: method, operation_id: operation_id, path: path, tag: tag)
        {
          method: method.upcase,
          path: path,
          name: operation_id,
          operation_id: operation_id,
          summary: operation_payload['summary'].presence || operation_payload['description'].presence || "#{method.upcase} #{path}",
          description: operation_payload['description'].presence,
          tag: tag,
          source: auth_context.mcp_access_policy.openapi_source_for(method.upcase),
          risk_level: risk_level,
          requires_confirmation: method.upcase != READ_METHOD,
          request_body: normalize_request_body(operation_payload['requestBody']),
          parameters: parameters.filter_map { |parameter| normalize_parameter(parameter) }.uniq { |parameter| [parameter[:in], parameter[:name]] }
        }
      end

      def normalize_parameter(parameter)
        parameter = dereference_schema(parameter)
        return unless parameter.is_a?(Hash)

        name = parameter['name'].to_s
        return if name.blank? || name == 'account_id'

        schema = parameter['schema'].is_a?(Hash) ? dereference_schema(parameter['schema']) : {}
        {
          name: name,
          in: parameter['in'].to_s,
          required: ActiveModel::Type::Boolean.new.cast(parameter['required']),
          description: parameter['description'].to_s,
          schema: schema
        }
      end

      def normalize_request_body(request_body)
        payload = dereference_schema(request_body)
        return unless payload.is_a?(Hash)

        content = payload['content']
        return unless content.is_a?(Hash)

        media_payload = content['application/json'] || content.find { |content_type, _| content_type.to_s.include?('json') }&.last
        return unless media_payload.is_a?(Hash)

        schema = dereference_schema(media_payload['schema'])
        return unless schema.is_a?(Hash)

        {
          required: ActiveModel::Type::Boolean.new.cast(payload['required']),
          description: payload['description'].to_s,
          schema: schema
        }
      end

      def dereference_schema(schema, seen = [])
        return schema unless schema.is_a?(Hash)

        ref = schema['$ref']
        if ref.present?
          return { 'type' => 'object' } if seen.include?(ref)

          resolved = resolve_ref(ref)
          return schema.except('$ref') if resolved.blank?

          return dereference_schema(resolved, seen + [ref])
        end

        schema.each_with_object({}) do |(key, value), memo|
          memo[key] =
            case value
            when Hash
              dereference_schema(value, seen)
            when Array
              value.map { |item| item.is_a?(Hash) ? dereference_schema(item, seen) : item }
            else
              value
            end
        end
      end

      def resolve_ref(ref)
        return unless ref.to_s.start_with?('#/')

        resolved = swagger
        ref.to_s.delete_prefix('#/').split('/').each do |segment|
          break if resolved.blank?

          decoded_segment = CGI.unescape(segment).gsub('~1', '/').gsub('~0', '~')
          resolved = resolved[decoded_segment]
        end
        resolved&.deep_dup
      end

      def tool_for(operation)
        read_only = operation[:method] == READ_METHOD
        {
          name: tool_name_for(operation),
          title: operation[:summary].to_s,
          description: tool_description(operation),
          inputSchema: input_schema_for(operation),
          annotations: {
            title: operation[:summary].to_s,
            readOnlyHint: read_only,
            destructiveHint: !read_only,
            idempotentHint: read_only
          },
          _meta: {
            provider: 'openapi',
            source: operation[:source],
            source_file: 'swagger/swagger.json',
            operation_id: operation[:operation_id],
            method: operation[:method],
            path: operation[:path],
            tag: operation[:tag],
            group_key: Onelink::Mcp::AccessPolicy.group_key(source: operation[:source], group: operation[:tag]),
            account_id: auth_context.account.id,
            risk_level: operation[:risk_level],
            requires_confirmation: operation[:requires_confirmation]
          }.compact
        }
      end

      def catalog_entry(operation)
        {
          id: operation[:operation_id].to_s,
          name: tool_name_for(operation),
          title: operation[:summary].to_s,
          description: operation[:description].presence || operation[:summary].to_s,
          source: operation[:source],
          group_name: operation[:tag],
          group_key: Onelink::Mcp::AccessPolicy.group_key(source: operation[:source], group: operation[:tag]),
          risk_level: operation[:risk_level],
          method: operation[:method],
          path: operation[:path],
          requires_confirmation: operation[:requires_confirmation],
          enabled_by_policy: auth_context.mcp_access_policy.allows_openapi_operation?(operation)
        }
      end

      def tool_name_for(operation)
        normalized_name = operation[:name].to_s.parameterize(separator: '_').tr('-', '_').squeeze('_')
        "#{TOOL_PREFIX}#{normalized_name}"
      end

      def tool_description(operation)
        [
          operation[:description].presence || operation[:summary].to_s,
          "OneLink REST API fallback: #{operation[:method]} #{operation[:path]}",
          "Risk: #{operation[:risk_level]}.",
          operation[:requires_confirmation] ? "Mutation calls require #{CONFIRM_ARGUMENT}: true." : nil
        ].compact.join("\n\n")
      end

      def input_schema_for(operation)
        properties = {}
        required = []

        operation[:parameters].each do |parameter|
          properties[parameter[:name]] = schema_for_parameter(parameter)
          required << parameter[:name] if parameter[:required]
        end

        if operation[:request_body].present?
          properties[REQUEST_BODY_ARGUMENT] = schema_for_request_body(operation[:request_body])
          required << REQUEST_BODY_ARGUMENT if operation[:request_body][:required]
        end

        if operation[:requires_confirmation]
          properties[CONFIRM_ARGUMENT] = {
            type: 'boolean',
            description: 'Required true to execute this mutating OneLink API operation through MCP.'
          }
          required << CONFIRM_ARGUMENT if auth_context.mcp_access_policy.require_confirmation_for_mutations?
          properties[IDEMPOTENCY_ARGUMENT] = {
            type: 'string',
            description: 'Optional idempotency key forwarded as Idempotency-Key for mutation calls.'
          }
        end

        {
          type: 'object',
          properties: properties,
          required: required.uniq
        }
      end

      def schema_for_parameter(parameter)
        schema = parameter[:schema].deep_dup
        schema = {} unless schema.is_a?(Hash)
        schema['type'] ||= 'string'
        schema['description'] = parameter[:description] if parameter[:description].present?
        schema
      end

      def schema_for_request_body(request_body)
        schema = request_body[:schema].deep_dup
        schema = {} unless schema.is_a?(Hash)
        schema['type'] ||= 'object'
        schema['description'] = request_body[:description] if request_body[:description].present?
        schema
      end

      def dispatch_request(operation, arguments)
        normalized_arguments = arguments.deep_stringify_keys
        idempotency_key = normalized_arguments.delete(IDEMPOTENCY_ARGUMENT)
        normalized_arguments.delete(CONFIRM_ARGUMENT)
        relative_path = build_relative_path(operation, normalized_arguments)
        body_payload = request_body_payload(operation, normalized_arguments)
        status, _headers, body = Rails.application.call(
          rack_env_for(
            relative_path,
            method: operation[:method],
            body_payload: body_payload,
            idempotency_key: idempotency_key
          )
        )
        raw_body = collect_body(body)
        parsed = parse_json(raw_body)
        redacted_parsed = redact_value(parsed)
        success = status.to_i.between?(200, 299)

        {
          content: [
            {
              type: 'text',
              text: response_text(raw_body: raw_body, parsed: redacted_parsed)
            }
          ],
          isError: !success
        }.tap do |payload|
          payload[:structuredContent] = redacted_parsed if success && (redacted_parsed.is_a?(Hash) || redacted_parsed.is_a?(Array))
        end
      ensure
        body&.close if body.respond_to?(:close)
      end

      def build_relative_path(operation, arguments)
        path = operation[:path].gsub('{account_id}', auth_context.account.id.to_s)
        path_parameters = operation[:parameters].select { |parameter| parameter[:in] == 'path' }
        query_parameters = operation[:parameters].select { |parameter| parameter[:in] == 'query' }

        path_parameters.each do |parameter|
          value = arguments.delete(parameter[:name])
          raise ArgumentError, "Missing required path parameter: #{parameter[:name]}" if value.blank? && parameter[:required]

          path = path.gsub("{#{parameter[:name]}}", CGI.escape(value.to_s))
        end

        query = query_parameters.each_with_object({}) do |parameter, memo|
          next unless arguments.key?(parameter[:name])

          value = arguments.delete(parameter[:name])
          next if value.nil?

          memo[parameter[:name]] = value
        end

        query.present? ? "#{path}?#{Rack::Utils.build_nested_query(query)}" : path
      end

      def request_body_payload(operation, arguments)
        return if operation[:request_body].blank?

        body_payload = if arguments.key?(REQUEST_BODY_ARGUMENT)
                         arguments.delete(REQUEST_BODY_ARGUMENT)
                       else
                         arguments.except(*RESERVED_ARGUMENT_KEYS)
                       end

        raise ArgumentError, "Missing required request body: #{REQUEST_BODY_ARGUMENT}" if body_payload.blank? && operation[:request_body][:required]

        body_payload.presence || {}
      end

      def rack_env_for(relative_path, method:, body_payload:, idempotency_key: nil)
        body_json = body_payload.nil? ? '' : JSON.generate(body_payload)
        Rack::MockRequest.env_for(
          relative_path,
          :method => method,
          :input => body_json,
          'HTTP_API_ACCESS_TOKEN' => auth_context.token_value,
          'HTTP_ACCEPT' => 'application/json',
          'CONTENT_TYPE' => 'application/json'
        ).tap do |env|
          env['HTTP_IDEMPOTENCY_KEY'] = idempotency_key.to_s if idempotency_key.present?
        end
      end

      def collect_body(body)
        return '' if body.blank?

        buffer = +''
        body.each { |chunk| buffer << chunk.to_s }
        buffer
      end

      def response_text(raw_body:, parsed:)
        return JSON.pretty_generate(parsed) if parsed.present?

        redact_value(raw_body.to_s).to_s
      rescue JSON::GeneratorError
        parsed.to_s
      end

      def redact_value(value)
        Captain::ToolTraceRedactor.call(value)
      rescue StandardError
        '[FILTERED]'
      end

      def audit_openapi_call(name:, operation:, arguments:, result: nil, error: nil)
        return if auth_context.assistant.blank?

        Captain::ToolExecutionAuditService.record(
          assistant: auth_context.assistant,
          scope_name: auth_context.scope_name,
          tool_definition: openapi_tool_definition(name: name, operation: operation),
          arguments: arguments,
          result: result,
          error: error,
          user: auth_context.user,
          runtime_context: {
            source: 'mcp_openapi',
            current_agent: Onelink::Mcp::Server::SERVER_NAME
          }
        )
      end

      def openapi_tool_definition(name:, operation:)
        {
          id: name,
          title: operation&.dig(:summary) || name,
          provider: 'openapi',
          risk_level: operation&.dig(:risk_level) || 'medium',
          requires_confirmation: operation&.dig(:requires_confirmation) || false
        }
      end

      def parse_json(raw_body)
        JSON.parse(raw_body)
      rescue JSON::ParserError, TypeError
        nil
      end

      def risk_level_for(method:, operation_id:, path:, tag:)
        normalized_method = method.to_s.upcase
        return 'low' if normalized_method == READ_METHOD
        return 'high' if normalized_method == 'DELETE'

        signature = [operation_id, path, tag].join(' ')
        signature.match?(HIGH_RISK_PATTERN) ? 'high' : 'medium'
      end

      def error_tool_response(message)
        {
          content: [
            {
              type: 'text',
              text: message.to_s
            }
          ],
          isError: true
        }
      end
    end
  end
end
