# frozen_string_literal: true

class Llm::RuntimePolicy
  THINKING_EFFORTS = %w[none low medium high].freeze
  MODERATION_FAILURE_MODES = %w[fail_open fail_closed].freeze
  RELEASE_GATE_KEYS = %w[
    enabled
    min_request_count
    max_error_rate
    max_provider_failure_rate
    max_payload_truncated_rate
    max_schema_invalid_rate
    max_tool_failure_rate
    max_moderation_skipped_rate
    max_avg_duration_ms
    max_p95_duration_ms
    max_cost_per_request
    max_error_rate_regression
    max_avg_duration_regression
  ].freeze
  AGENT_HIGH_RISK_TOOL_MODES = %w[disabled enabled].freeze
  TRACE_CAPTURE_KEYS = %w[trace_input_capture trace_output_capture].freeze
  THINKING_BUDGETS = {
    'low' => 2_048,
    'medium' => 4_096,
    'high' => 8_192
  }.freeze

  class << self
    def thinking_options(feature:, model:, account: nil, preferences: nil)
      effort = runtime_preferences(account, preferences)["#{feature}_thinking_effort"].to_s
      return nil if effort.blank? || effort == 'none'
      return nil unless Llm::Models.supports_thinking?(model, account: account)

      options = { effort: effort }
      options[:budget] = budget_for(model, effort) if budget_required?(model, account: account)
      options
    end

    def moderation_enabled?(feature:, account: nil, preferences: nil)
      preferences = runtime_preferences(account, preferences)
      feature_key = "#{feature}_moderation"

      return ActiveModel::Type::Boolean.new.cast(preferences[feature_key]) if preferences.key?(feature_key)

      false
    end

    def moderation_failure_mode(feature:, account: nil, preferences: nil)
      mode = runtime_preferences(account, preferences)["#{feature}_moderation_failure_mode"].presence
      mode ||= runtime_preferences(account, preferences)['moderation_failure_mode'].presence
      mode = mode.to_s
      return mode if MODERATION_FAILURE_MODES.include?(mode)

      'fail_open'
    end

    def fail_closed_moderation?(feature:, account: nil, preferences: nil)
      moderation_failure_mode(
        feature: feature,
        account: account,
        preferences: preferences
      ) == 'fail_closed'
    end

    def safety_blocklist(feature:, account: nil, preferences: nil)
      preferences = runtime_preferences(account, preferences)
      global = normalize_string_list(preferences['safety_blocklist'])
      feature_specific = normalize_string_list(preferences["#{feature}_safety_blocklist"])

      (global + feature_specific).uniq
    end

    def release_gate_config(account: nil, preferences: nil)
      config = runtime_preferences(account, preferences)['release_gate']
      normalized = config.to_h.stringify_keys.slice(*RELEASE_GATE_KEYS)

      {
        enabled: boolean_or_default(normalized['enabled'], default: true),
        min_request_count: integer_or_default(normalized['min_request_count'], default: nil),
        max_error_rate: float_or_default(normalized['max_error_rate'], default: nil),
        max_provider_failure_rate: float_or_default(normalized['max_provider_failure_rate'], default: nil),
        max_payload_truncated_rate: float_or_default(normalized['max_payload_truncated_rate'], default: nil),
        max_schema_invalid_rate: float_or_default(normalized['max_schema_invalid_rate'], default: nil),
        max_tool_failure_rate: float_or_default(normalized['max_tool_failure_rate'], default: nil),
        max_moderation_skipped_rate: float_or_default(normalized['max_moderation_skipped_rate'], default: nil),
        max_avg_duration_ms: integer_or_default(normalized['max_avg_duration_ms'], default: nil),
        max_p95_duration_ms: integer_or_default(normalized['max_p95_duration_ms'], default: nil),
        max_cost_per_request: float_or_default(normalized['max_cost_per_request'], default: nil),
        max_error_rate_regression: float_or_default(normalized['max_error_rate_regression'], default: nil),
        max_avg_duration_regression: float_or_default(normalized['max_avg_duration_regression'], default: nil)
      }.compact
    end

    def agent_high_risk_tools_enabled?(account: nil, preferences: nil)
      preferences = runtime_preferences(account, preferences)
      mode = preferences['agent_high_risk_tools'].to_s
      return mode == 'enabled' if AGENT_HIGH_RISK_TOOL_MODES.include?(mode)

      ActiveModel::Type::Boolean.new.cast(preferences['agent_high_risk_tools'])
    end

    def agent_high_risk_tool_allowed?(tool_id, account: nil, preferences: nil)
      return true if agent_high_risk_tools_enabled?(account: account, preferences: preferences)

      normalize_string_list(runtime_preferences(account, preferences)['agent_high_risk_tool_ids']).include?(tool_id.to_s.downcase)
    end

    def agent_permissioned_tool_allowed?(tool_id, account: nil, preferences: nil)
      normalize_string_list(
        runtime_preferences(account, preferences)['agent_permissioned_tool_ids']
      ).include?(tool_id.to_s.downcase)
    end

    def trace_input_capture?(account: nil, preferences: nil)
      trace_capture_enabled?('trace_input_capture', account: account, preferences: preferences)
    end

    def trace_output_capture?(account: nil, preferences: nil)
      trace_capture_enabled?('trace_output_capture', account: account, preferences: preferences)
    end

    private

    def runtime_preferences(account, preferences)
      return preferences.to_h.stringify_keys if preferences.present?
      return account.captain_preferences[:runtime].to_h.stringify_keys if account.respond_to?(:captain_preferences)

      {}
    end

    def budget_required?(model, account: nil)
      Llm::Config.provider_for_model(model, account: account) == 'anthropic'
    end

    def budget_for(_model, effort)
      THINKING_BUDGETS.fetch(effort.to_s, THINKING_BUDGETS['medium'])
    end

    def normalize_string_list(value)
      Array(value).filter_map do |entry|
        normalized = entry.to_s.strip
        normalized.downcase if normalized.present?
      end
    end

    def integer_or_default(value, default:)
      return default if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      default
    end

    def float_or_default(value, default:)
      return default if value.blank?

      Float(value)
    rescue ArgumentError, TypeError
      default
    end

    def boolean_or_default(value, default:)
      return default if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def trace_capture_enabled?(key, account:, preferences:)
      boolean_or_default(
        runtime_preferences(account, preferences)[key],
        default: default_trace_capture_enabled?
      )
    end

    def default_trace_capture_enabled?
      return true unless defined?(Rails) && Rails.respond_to?(:env)

      !Rails.env.production?
    end
  end
end
