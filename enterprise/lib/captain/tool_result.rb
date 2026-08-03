# frozen_string_literal: true

class Captain::ToolResult
  NORMALIZED_KEYS = %i[success data message error retryable audit].freeze
  MCP_ERROR_KEY = 'isError'
  MCP_ERROR_MESSAGE = 'MCP tool returned an error'
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
      payload = normalized_payload(result)

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
      return render_error(normalized, fallback_message) if error?(normalized)
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

    def normalized_payload(result)
      return normalize_mcp_hash(result) if mcp_result_hash?(result)
      return normalize_hash(result) if normalized_hash?(result)

      normalize_raw(result)
    end

    def render_error(normalized, fallback_message)
      message = normalized[:error].presence || normalized[:message].presence || fallback_message
      return error_output(message) if normalized[:data].blank?

      error_output(
        serialize_payload(
          {
            error: message,
            data: normalized[:data],
            retryable: normalized[:retryable]
          }.compact
        )
      )
    end

    def mcp_result_hash?(result)
      result.is_a?(Hash) && result.keys.map(&:to_s).include?(MCP_ERROR_KEY)
    end

    def normalize_mcp_hash(result)
      normalized = Captain::EncodingNormalizer.utf8(result).deep_symbolize_keys
      return { success: true, data: normalized } unless truthy_error?(normalized[:isError])

      {
        success: false,
        error: mcp_error_message(normalized),
        data: normalized[:structuredContent]
      }
    end

    def mcp_error_message(result)
      structured_content = result[:structuredContent]
      structured_error = structured_content[:error] if structured_content.is_a?(Hash)
      candidates = [
        structured_error.is_a?(Hash) ? structured_error[:message] : nil,
        structured_error.is_a?(String) ? structured_error : nil,
        structured_content.is_a?(Hash) ? structured_content[:message] : nil,
        mcp_content_text(result[:content])
      ]
      candidates.compact_blank.first || MCP_ERROR_MESSAGE
    end

    def mcp_content_text(content)
      Array(content).filter_map do |item|
        next item if item.is_a?(String)
        next unless item.is_a?(Hash)

        item[:text] || item['text']
      end.join("\n").strip
    end

    def normalized_hash?(result)
      return false unless result.is_a?(Hash)

      result.keys.map(&:to_s).intersect?(NORMALIZED_KEYS.map(&:to_s))
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
      return value if value.in?([true, false])

      value.present?
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
