# frozen_string_literal: true

class Llm::RuntimeGuardrailAction
  ACTIONS = %w[disabled flag block].freeze
  DEFAULTS = {
    'prompt_injection' => 'block',
    'sensitive_info' => 'block'
  }.freeze
  ALIASES = {
    'off' => 'disabled',
    'false' => 'disabled',
    'none' => 'disabled',
    'on' => 'block',
    'true' => 'block',
    'enabled' => 'block',
    'enforce' => 'block',
    'enforced' => 'block',
    'monitor' => 'flag',
    'monitored' => 'flag',
    'audit' => 'flag'
  }.freeze

  class << self
    def for(guardrail:, feature:, preferences:)
      guardrail_key = guardrail.to_s
      configured = first_present_preference(
        preferences.to_h.stringify_keys,
        [
          "#{feature}_#{guardrail_key}_guardrail",
          "#{feature}_#{guardrail_key}",
          "#{guardrail_key}_guardrail",
          guardrail_key
        ]
      )

      normalize(configured, default: DEFAULTS.fetch(guardrail_key, 'disabled'))
    end

    def normalize(value, default:)
      return default if value.nil? || value == ''
      return value ? 'block' : 'disabled' if value == true || value == false

      normalized = value.to_s.strip.downcase.tr('-', '_')
      action = ALIASES.fetch(normalized, normalized.tr('_', '-'))
      ACTIONS.include?(action) ? action : default
    end

    private

    def first_present_preference(preferences, keys)
      keys.each do |key|
        next unless preferences.key?(key)

        return preferences[key]
      end

      nil
    end
  end
end
