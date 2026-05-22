# frozen_string_literal: true

class Llm::Monitoring::PayloadSanitizer
  MAX_STRING_LENGTH = 2_000
  MAX_ARRAY_ITEMS = 20
  MAX_HASH_KEYS = 50
  REDACTED = '[REDACTED]'
  TRUNCATED_SUFFIX = '...[TRUNCATED]'.freeze
  TOKEN_USAGE_KEYS = %w[
    cached_tokens completion_tokens input_tokens output_tokens prompt_tokens reasoning_tokens thinking_tokens token_count total_tokens
  ].freeze
  SENSITIVE_KEY_PATTERN = /(authorization|api[_-]?key|token|secret|password|cookie)/i
  RAW_CONTENT_KEY_PATTERN = /\A(raw_)?(prompt|messages|input|output|response|content)\z/i

  class << self
    def call(payload)
      sanitize_value(payload)
    end

    private

    def sanitize_value(value, key: nil)
      return REDACTED if sensitive_key?(key)

      case value
      when Hash
        sanitize_hash(value)
      when Array
        sanitized_items = value.first(MAX_ARRAY_ITEMS).map { |entry| sanitize_value(entry) }
        return sanitized_items if value.length <= MAX_ARRAY_ITEMS

        sanitized_items + [TRUNCATED_SUFFIX]
      when String
        truncate_string(value)
      else
        value
      end
    end

    def sensitive_key?(key)
      key.present? && TOKEN_USAGE_KEYS.exclude?(key.to_s) && (
        key.match?(SENSITIVE_KEY_PATTERN) || key.match?(RAW_CONTENT_KEY_PATTERN)
      )
    end

    def sanitize_hash(value)
      limited_pairs = value.first(MAX_HASH_KEYS)
      sanitized = limited_pairs.each_with_object({}) do |(child_key, child_value), result|
        result[child_key] = sanitize_value(child_value, key: child_key.to_s)
      end
      return sanitized if value.size <= MAX_HASH_KEYS

      sanitized.merge('_truncated_keys_count' => value.size - MAX_HASH_KEYS)
    end

    def truncate_string(value)
      return value if value.length <= MAX_STRING_LENGTH

      "#{value.first(MAX_STRING_LENGTH)}#{TRUNCATED_SUFFIX}"
    end
  end
end
