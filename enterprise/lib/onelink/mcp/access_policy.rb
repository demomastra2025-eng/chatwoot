# frozen_string_literal: true

module Onelink
  module Mcp
    class AccessPolicy
      SOURCE_CAPTAIN = 'captain'
      SOURCE_OPENAPI_READ = 'openapi_read'
      SOURCE_OPENAPI_WRITE = 'openapi_write'
      OPENAPI_GROUP_SOURCE = 'openapi'
      DEFAULT_MAX_RISK_LEVEL = 'medium'
      RISK_ORDER = {
        'low' => 0,
        'medium' => 1,
        'high' => 2,
        'custom' => 3
      }.freeze
      DEFAULT_SOURCES = {
        SOURCE_CAPTAIN => true,
        SOURCE_OPENAPI_READ => true,
        SOURCE_OPENAPI_WRITE => false
      }.freeze
      ARRAY_KEYS = %w[
        allowed_groups
        blocked_groups
        allowed_tool_ids
        blocked_tool_ids
        allowed_openapi_operation_ids
        blocked_openapi_operation_ids
      ].freeze

      attr_reader :account, :config, :user

      def initialize(auth_context: nil, account: nil, user: nil, config: nil)
        @account = account || auth_context&.account
        @user = user || auth_context&.user
        @config = self.class.normalize(config || @account&.mcp_access)
      end

      def self.normalize(raw_config)
        raw = normalize_hash(raw_config)
        sources = normalize_sources(raw['sources'])
        max_risk_level = normalize_risk_level(raw['max_risk_level'])

        {
          'enabled' => boolean_value(raw.fetch('enabled', true), default: true),
          'sources' => sources,
          'max_risk_level' => max_risk_level,
          'require_confirmation_for_mutations' => boolean_value(raw.fetch('require_confirmation_for_mutations', true), default: true),
          'allowed_groups' => normalize_array(raw['allowed_groups']),
          'blocked_groups' => normalize_array(raw['blocked_groups']),
          'allowed_tool_ids' => normalize_array(raw['allowed_tool_ids']),
          'blocked_tool_ids' => normalize_array(raw['blocked_tool_ids']),
          'allowed_openapi_operation_ids' => normalize_array(raw['allowed_openapi_operation_ids']),
          'blocked_openapi_operation_ids' => normalize_array(raw['blocked_openapi_operation_ids'])
        }
      end

      def self.defaults
        normalize({})
      end

      def self.group_key(source:, group:)
        normalized_source = source.to_s.start_with?('openapi') ? OPENAPI_GROUP_SOURCE : source.to_s
        normalized_group = group.to_s.presence || 'Other'
        "#{normalized_source}:#{normalized_group}"
      end

      def self.normalize_hash(raw_config)
        raw = raw_config.respond_to?(:to_unsafe_h) ? raw_config.to_unsafe_h : raw_config
        raw = raw.to_h if raw.respond_to?(:to_h)
        raw.is_a?(Hash) ? raw.deep_stringify_keys : {}
      end

      def self.normalize_sources(raw_sources)
        raw = normalize_hash(raw_sources)
        DEFAULT_SOURCES.each_with_object({}) do |(source, default_value), memo|
          memo[source] = boolean_value(raw.fetch(source, default_value), default: default_value)
        end
      end

      def self.normalize_risk_level(value)
        normalized = value.to_s.presence || DEFAULT_MAX_RISK_LEVEL
        RISK_ORDER.key?(normalized) ? normalized : DEFAULT_MAX_RISK_LEVEL
      end

      def self.normalize_array(value)
        Array(value).filter_map do |item|
          normalized = item.to_s.strip
          normalized.presence
        end.uniq
      end

      def self.boolean_value(value, default: false)
        return default if value.nil?

        ActiveModel::Type::Boolean.new.cast(value)
      end

      def enabled?
        config['enabled'] == true
      end

      def source_enabled?(source)
        enabled? && config.fetch('sources', {}).fetch(source.to_s, false) == true
      end

      def max_risk_level
        config['max_risk_level'].presence || DEFAULT_MAX_RISK_LEVEL
      end

      def require_confirmation_for_mutations?
        config['require_confirmation_for_mutations'] == true
      end

      def allows_captain_tool?(tool_definition)
        tool = tool_definition.with_indifferent_access
        allows_entry?(
          id: tool[:id],
          source: SOURCE_CAPTAIN,
          group: tool[:group_name],
          risk_level: tool[:risk_level],
          explicit_ids: config['allowed_tool_ids'],
          blocked_ids: config['blocked_tool_ids']
        )
      end

      def allows_openapi_operation?(operation)
        source = openapi_source_for(operation[:method])
        allows_entry?(
          id: operation[:operation_id] || operation[:name],
          source: source,
          group: operation[:tag],
          risk_level: operation[:risk_level],
          explicit_ids: config['allowed_openapi_operation_ids'],
          blocked_ids: config['blocked_openapi_operation_ids']
        )
      end

      def allows_tool_entry?(entry)
        normalized = entry.with_indifferent_access
        explicit_key = normalized[:source].to_s.start_with?('openapi') ? 'allowed_openapi_operation_ids' : 'allowed_tool_ids'
        blocked_key = normalized[:source].to_s.start_with?('openapi') ? 'blocked_openapi_operation_ids' : 'blocked_tool_ids'
        allows_entry?(
          id: normalized[:id],
          source: normalized[:source],
          group: normalized[:group_name] || normalized[:tag],
          risk_level: normalized[:risk_level],
          explicit_ids: config[explicit_key],
          blocked_ids: config[blocked_key]
        )
      end

      def group_allowed?(source:, group:)
        key = self.class.group_key(source: source, group: group)
        return false if config['blocked_groups'].include?(key)

        allowed_groups = config['allowed_groups']
        allowed_groups.blank? || allowed_groups.include?(key)
      end

      def risk_allowed?(risk_level, explicit: false)
        return true if explicit

        RISK_ORDER.fetch(normalize_risk_level(risk_level), RISK_ORDER[DEFAULT_MAX_RISK_LEVEL]) <= RISK_ORDER.fetch(max_risk_level)
      end

      def openapi_source_for(method)
        method.to_s.upcase == 'GET' ? SOURCE_OPENAPI_READ : SOURCE_OPENAPI_WRITE
      end

      def mutation_confirmed?(arguments)
        return true unless require_confirmation_for_mutations?

        self.class.boolean_value(arguments.to_h.with_indifferent_access[:_confirm])
      end

      private

      def allows_entry?(id:, source:, group:, risk_level:, explicit_ids:, blocked_ids:)
        normalized_id = id.to_s
        normalized_source = source.to_s
        return false unless source_enabled?(normalized_source)
        return false if blocked_ids.include?(normalized_id)
        return false if explicit_ids.present? && explicit_ids.exclude?(normalized_id)
        return false unless group_allowed?(source: normalized_source, group: group)

        explicit = explicit_ids.include?(normalized_id)
        risk_allowed?(risk_level, explicit: explicit)
      end

      def normalize_risk_level(value)
        self.class.normalize_risk_level(value)
      end
    end
  end
end
