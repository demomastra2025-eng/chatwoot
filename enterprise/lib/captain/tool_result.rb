# frozen_string_literal: true

class Captain::ToolResult
  NORMALIZED_KEYS = %i[success data message error retryable audit].freeze
  ERROR_PREFIX = 'ERROR:'
  DEFAULT_SUCCESS_MESSAGE = 'Done'

  class << self
    def success(message: nil, data: nil, audit: nil)
      normalize(
        {
          success: true,
          message: message,
          data: data,
          audit: audit
        }
      )
    end

    def failure(error:, message: nil, data: nil, retryable: nil, audit: nil)
      normalize(
        {
          success: false,
          message: message,
          data: data,
          error: error_message(error),
          retryable: retryable,
          audit: audit
        }
      )
    end

    def normalize(result, error: nil, retryable: nil, audit: nil)
      payload = if normalized_hash?(result)
                  normalize_hash(result)
                else
                  normalize_raw(result)
                end

      if error.present?
        payload[:error] = error_message(error)
        payload[:success] = false
      elsif payload[:error].present?
        payload[:success] = false
      end

      payload[:retryable] = retryable unless retryable.nil?
      payload[:audit] = audit if audit.present?
      payload.compact
    end

    def error?(result)
      normalized = normalize(result)
      normalized[:success] == false || normalized[:error].present?
    end

    def render(result, fallback_message: DEFAULT_SUCCESS_MESSAGE)
      normalized = normalize(result)
      return error_output(normalized[:error].presence || normalized[:message].presence || fallback_message) if error?(normalized)
      return normalized[:message].to_s if normalized[:message].present? && normalized[:data].blank?
      return serialize_payload(normalized[:data]) if normalized[:data].present? && normalized[:message].blank?

      if normalized[:message].present? && normalized[:data].present?
        return serialize_payload({ message: normalized[:message],
                                   data: normalized[:data] })
      end

      fallback_message
    end

    def success_output(message: nil, data: nil, audit: nil)
      render(success(message: message, data: data, audit: audit))
    end

    def failure_output(error:, message: nil, data: nil, retryable: nil, audit: nil)
      render(failure(error: error, message: message, data: data, retryable: retryable, audit: audit))
    end

    def error_output(message)
      text = Captain::EncodingNormalizer.string(message.to_s).strip
      return ERROR_PREFIX if text.blank?
      return text if text.start_with?(ERROR_PREFIX)

      "#{ERROR_PREFIX} #{text}"
    end

    private

    def normalized_hash?(result)
      return false unless result.is_a?(Hash)

      (result.keys.map(&:to_s) & NORMALIZED_KEYS.map(&:to_s)).any?
    end

    def normalize_hash(result)
      normalized = Captain::EncodingNormalizer.utf8(result).deep_symbolize_keys
      {
        success: normalized.key?(:success) ? normalized[:success] : !truthy_error?(normalized[:error]),
        data: normalized[:data],
        message: normalized[:message],
        error: normalized[:error],
        retryable: normalized[:retryable],
        audit: normalized[:audit]
      }
    end

    def normalize_raw(result)
      return normalize_raw(result.content) if halt_result?(result)

      if result.is_a?(String)
        normalized_result = Captain::EncodingNormalizer.string(result)
        return { success: false, error: normalized_result } if error_string?(normalized_result)

        return { success: true, message: normalized_result }
      end

      { success: true, data: Captain::EncodingNormalizer.utf8(result) }
    end

    def error_string?(result)
      result.is_a?(String) && result.start_with?(ERROR_PREFIX)
    end

    def truthy_error?(value)
      case value
      when String
        value.present?
      when TrueClass, FalseClass
        value
      else
        value.present?
      end
    end

    def error_message(error)
      return Captain::EncodingNormalizer.string(error.to_s) unless error.is_a?(StandardError)

      Captain::EncodingNormalizer.string("#{error.class.name}: #{error.message}")
    end

    def serialize_payload(value)
      return Captain::EncodingNormalizer.string(value) if value.is_a?(String)

      JSON.generate(Captain::EncodingNormalizer.utf8(value))
    rescue StandardError
      Captain::EncodingNormalizer.string(value.to_s)
    end

    def halt_result?(result)
      defined?(RubyLLM::Tool::Halt) && result.is_a?(RubyLLM::Tool::Halt)
    end
  end
end
