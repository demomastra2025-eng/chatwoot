# frozen_string_literal: true

module Onelink
  module Mcp
    class CaptainToolAdapter
      RESERVED_ARGUMENT_KEYS = %w[_meta __mcp mcp_context].freeze

      def initialize(auth_context:)
        @auth_context = auth_context
      end

      def tools
        with_llm_runtime_cache do
          executable_tool_definitions.filter_map do |tool_definition|
            next unless auth_context.mcp_access_policy.allows_captain_tool?(tool_definition)

            mcp_tool_definition(tool_definition)
          end
        end
      end

      def catalog_entries
        with_llm_runtime_cache do
          catalog_tool_definitions.map { |tool_definition| catalog_entry(tool_definition) }
        end
      end

      def call_tool(name:, arguments:, meta: {})
        tool_definition = tool_definition_for(name)
        return error_tool_response("Tool '#{name}' is not available for this workspace") if tool_definition.blank?
        unless auth_context.mcp_access_policy.allows_captain_tool?(tool_definition)
          return error_tool_response("Tool '#{name}' is disabled by this workspace MCP access policy")
        end

        execution_arguments = sanitized_arguments(arguments)
        tool = build_tool(tool_definition, arguments: execution_arguments, meta: meta)
        return error_tool_response("Tool '#{name}' is not active for this workspace") if tool.blank? || !tool.active?

        result = tool.execute(**execution_arguments.symbolize_keys)
        result_to_mcp_response(result)
      rescue StandardError => e
        Rails.logger.warn do
          "#{self.class.name} failed account=#{auth_context.account.id} user=#{auth_context.user.id} tool=#{name}: #{e.class} #{e.message}"
        end
        error_tool_response(redact_value("#{e.class.name}: #{e.message}").to_s)
      end

      private

      attr_reader :auth_context

      def tool_definition_for(name)
        executable_tool_definitions.find { |tool_definition| tool_definition[:id].to_s == name.to_s }
      end

      def catalog_tool_definitions
        auth_context.administrator? ? available_tool_definitions : executable_tool_definitions
      end

      def executable_tool_definitions
        @executable_tool_definitions ||= available_tool_definitions.select { |tool| tool_visible_to_user?(tool) }
      end

      def available_tool_definitions
        @available_tool_definitions ||= begin
          available = Captain::ToolCatalog.available_tools_for(auth_context.assistant, auth_context.scope_name)
          allowed_ids = allowed_tool_ids_for(available)

          available
            .select { |tool| allowed_ids.include?(tool[:id].to_s) }
            .map { |tool| tool.with_indifferent_access }
        end
      end

      def allowed_tool_ids_for(available_tools)
        available_ids = available_tools.map { |tool| tool[:id].to_s }
        raw_access = auth_context.assistant.config.is_a?(Hash) ? auth_context.assistant.config['tool_access'] : nil
        raw_access = raw_access.to_h.deep_stringify_keys if raw_access.respond_to?(:to_h)
        return available_ids unless raw_access.is_a?(Hash) && raw_access.key?(auth_context.scope_name)

        raw_scope = raw_access[auth_context.scope_name]
        raw_scope = raw_scope.to_h.deep_stringify_keys if raw_scope.respond_to?(:to_h)
        raw_scope = {} unless raw_scope.is_a?(Hash)
        default_ids = Captain::ToolAccess.default_tool_ids_for(auth_context.scope_name, available_tools)
        enabled = raw_scope.key?('enabled') ? ActiveModel::Type::Boolean.new.cast(raw_scope['enabled']) : default_ids.any?
        return [] unless enabled

        configured_ids = Array(raw_scope['tool_ids']).map(&:to_s)
        selected_ids = raw_scope.key?('tool_ids') ? configured_ids : default_ids
        Captain::ToolAccess.sanitize_tool_ids(selected_ids, available_ids)
      end

      def with_llm_runtime_cache(&)
        return yield unless defined?(Llm::Config) && Llm::Config.respond_to?(:with_runtime_cache)

        Llm::Config.with_runtime_cache(&)
      end

      def tool_visible_to_user?(tool_definition)
        return false unless Captain::ToolPolicy.execution_allowed?(
          tool_definition,
          assistant: auth_context.assistant,
          scope_name: auth_context.scope_name,
          user: auth_context.user
        )

        return true if auth_context.administrator?

        !high_risk_or_confirmation_required?(tool_definition)
      end

      def high_risk_or_confirmation_required?(tool_definition)
        risk_level = tool_definition[:risk_level].to_s
        ActiveModel::Type::Boolean.new.cast(tool_definition[:requires_confirmation]) ||
          %w[high custom].include?(risk_level)
      end

      def mcp_tool_definition(tool_definition)
        schema = input_schema_for(tool_definition)
        return if schema.blank?

        metadata = Captain::ToolPolicy.selection_metadata(tool_definition)
        risk_level = risk_level_for(tool_definition, metadata: metadata)
        idempotent = ActiveModel::Type::Boolean.new.cast(tool_definition[:idempotent]) || risk_level == 'low'
        destructive = %w[high custom].include?(risk_level)
        requires_confirmation = confirmation_required_for(tool_definition, metadata: metadata)

        {
          name: tool_definition[:id].to_s,
          title: tool_definition[:title].presence || tool_definition[:id].to_s.humanize,
          description: tool_description(tool_definition, requires_confirmation: requires_confirmation, risk_level: risk_level),
          inputSchema: normalize_input_schema(schema),
          annotations: {
            title: tool_definition[:title].presence || tool_definition[:id].to_s.humanize,
            readOnlyHint: risk_level == 'low',
            destructiveHint: destructive,
            idempotentHint: idempotent
          },
          _meta: {
            provider: tool_definition[:provider].presence || 'captain',
            group_name: tool_definition[:group_name],
            risk_level: risk_level,
            requires_confirmation: requires_confirmation,
            account_id: auth_context.account.id,
            assistant_id: auth_context.assistant.persisted? ? auth_context.assistant.id : nil,
            scope_name: auth_context.scope_name
          }.compact
        }
      rescue StandardError => e
        Rails.logger.warn do
          "#{self.class.name} failed to expose tool #{tool_definition[:id]} account=#{auth_context.account.id}: #{e.class} #{e.message}"
        end
        nil
      end

      def tool_description(tool_definition, requires_confirmation:, risk_level:)
        suffixes = []
        suffixes << "Risk: #{risk_level}."
        suffixes << 'Operator confirmation is required before execution.' if requires_confirmation

        [tool_definition[:description].to_s, suffixes.join(' ')].reject(&:blank?).join('\n\n')
      end

      def catalog_entry(tool_definition)
        metadata = Captain::ToolPolicy.selection_metadata(tool_definition)
        risk_level = risk_level_for(tool_definition, metadata: metadata)
        source = Onelink::Mcp::AccessPolicy::SOURCE_CAPTAIN

        {
          id: tool_definition[:id].to_s,
          name: tool_definition[:id].to_s,
          title: tool_definition[:title].presence || tool_definition[:id].to_s.humanize,
          description: tool_definition[:description].to_s,
          source: source,
          group_name: tool_definition[:group_name].presence || 'Other',
          group_key: Onelink::Mcp::AccessPolicy.group_key(source: source, group: tool_definition[:group_name]),
          risk_level: risk_level,
          requires_confirmation: confirmation_required_for(tool_definition, metadata: metadata),
          enabled_by_policy: auth_context.mcp_access_policy.allows_captain_tool?(tool_definition)
        }
      end

      def risk_level_for(tool_definition, metadata: nil)
        metadata ||= Captain::ToolPolicy.selection_metadata(tool_definition)
        (metadata[:risk_level].presence || tool_definition[:risk_level].presence || 'medium').to_s
      end

      def confirmation_required_for(tool_definition, metadata: nil)
        metadata ||= Captain::ToolPolicy.selection_metadata(tool_definition)
        ActiveModel::Type::Boolean.new.cast(metadata[:requires_confirmation] || tool_definition[:requires_confirmation])
      end

      def input_schema_for(tool_definition)
        return tool_definition[:input_schema] if tool_definition[:input_schema].present?

        build_tool(tool_definition)&.params_schema
      end

      def normalize_input_schema(schema)
        normalized = schema.respond_to?(:as_json) ? schema.as_json : schema
        normalized = normalized.deep_stringify_keys if normalized.respond_to?(:deep_stringify_keys)
        normalized = {} unless normalized.is_a?(Hash)
        normalized['type'] ||= 'object'
        normalized['properties'] = {} unless normalized['properties'].is_a?(Hash)
        normalized['required'] = Array(normalized['required']).map(&:to_s)
        normalized
      end

      def build_tool(tool_definition, arguments: {}, meta: {})
        Captain::ToolCatalog.build_tool(
          tool_definition,
          assistant: auth_context.assistant,
          scope_name: auth_context.scope_name,
          user: auth_context.user,
          conversation: conversation_for(arguments, meta),
          copilot_thread: copilot_thread_for(meta)
        )
      end

      def conversation_for(arguments, meta)
        conversation_id = meta_value(meta, 'conversation_id') || arguments[:conversation_id] || arguments['conversation_id']
        return if conversation_id.blank?

        auth_context.account.conversations.find_by(id: conversation_id) ||
          auth_context.account.conversations.find_by(display_id: conversation_id)
      end

      def copilot_thread_for(meta)
        thread_id = meta_value(meta, 'copilot_thread_id')
        return if thread_id.blank?

        auth_context.account
                    .copilot_threads
                    .where(user_id: auth_context.user.id, assistant_id: auth_context.assistant.id)
                    .find_by(id: thread_id)
      end

      def meta_value(meta, key)
        return if meta.blank?

        meta.with_indifferent_access[key]
      end

      def sanitized_arguments(arguments)
        normalized = arguments.respond_to?(:to_h) ? arguments.to_h : {}
        normalized = normalized.deep_stringify_keys if normalized.respond_to?(:deep_stringify_keys)
        normalized.except(*RESERVED_ARGUMENT_KEYS)
      end

      def result_to_mcp_response(result)
        normalized = Captain::ToolResult.normalize(result)
        text = response_text(normalized)
        parsed = parse_json(text)
        payload = {
          content: [
            {
              type: 'text',
              text: text
            }
          ],
          isError: normalized[:success] == false
        }
        payload[:structuredContent] = parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)
        payload
      end

      def response_text(normalized)
        return redact_value(normalized[:error]).to_s if normalized[:error].present?
        return redact_value(normalized[:message]).to_s if normalized[:message].present?
        return JSON.pretty_generate(redact_value(normalized[:data])) if normalized[:data].present?

        'Done'
      rescue JSON::GeneratorError
        redact_value(normalized[:data]).to_s
      end

      def redact_value(value)
        Captain::ToolTraceRedactor.call(value)
      rescue StandardError
        '[FILTERED]'
      end

      def parse_json(text)
        JSON.parse(text)
      rescue JSON::ParserError, TypeError
        nil
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
