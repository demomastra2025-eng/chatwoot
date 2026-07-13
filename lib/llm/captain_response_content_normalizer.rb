# frozen_string_literal: true

class Llm::CaptainResponseContentNormalizer
  SCHEMA_NAME = 'Captain::ResponseSchema'
  DEFAULT_REASONING = 'Response generated from the current conversation and available tool results.'
  INVALID_PUBLIC_RESPONSE_LITERALS = %w[true false null response].freeze

  class << self
    def apply_defaults(schema, content)
      return content unless applicable?(schema)
      return content unless content.respond_to?(:with_indifferent_access)

      payload = content.with_indifferent_access
      apply_reasoning_default!(payload)
      payload['artifact_ids'] = normalized_artifact_ids(payload['artifact_ids'])
      apply_text_default!(payload, 'handoff_message')
      apply_text_default!(payload, 'handoff_reason')
      apply_text_default!(payload, 'handoff_status_reason')
      payload
    end

    def plain_text_fallback(schema, content)
      return unless applicable?(schema)
      return unless content.is_a?(String)

      text = strip_provider_reasoning(content)
      return if text.blank? || json_document_like?(text) || Llm::JsonDocumentExtractor.call(text).present?

      {
        response: text,
        reasoning: DEFAULT_REASONING,
        artifact_ids: [],
        handoff_message: '',
        handoff_reason: '',
        handoff_status_reason: ''
      }
    end

    def applicable?(schema)
      Llm::StructuredOutputSchema.name_for(schema) == SCHEMA_NAME
    end

    def invalid_public_response?(value)
      return true unless value.is_a?(String)

      INVALID_PUBLIC_RESPONSE_LITERALS.include?(value.strip.downcase)
    end

    def invalid_public_response_message(value)
      "Model output returned invalid public response #{value.inspect}"
    end

    private

    def apply_reasoning_default!(payload)
      apply_text_default!(payload, 'reasoning')
      payload['reasoning'] = DEFAULT_REASONING if payload['reasoning'].blank? && payload['response'].to_s.strip.present?
    end

    def apply_text_default!(payload, key)
      unless payload.key?(key)
        payload[key] = ''
        return
      end

      return unless payload[key].nil? || payload[key].is_a?(String)

      payload[key] = payload[key].presence.to_s
    end

    def normalized_artifact_ids(value)
      case value
      when Array
        value.filter_map { |artifact_id| artifact_id.to_s.strip.presence }
      when String
        value.split(/[,\s]+/).filter_map(&:presence)
      else
        []
      end
    end

    def strip_provider_reasoning(content)
      stripped = content.to_s
                        .gsub(%r{<think>.*?</think>}mi, '')
                        .gsub(/\A```(?:json)?\s*/mi, '')
                        .gsub(/\s*```\z/m, '')
                        .strip
      return '' if stripped.match?(%r{</?think\b}i)

      stripped
    end

    def json_document_like?(content)
      stripped = content.to_s.strip
      (stripped.start_with?('{') && stripped.end_with?('}')) ||
        (stripped.start_with?('[') && stripped.end_with?(']'))
    end
  end
end
