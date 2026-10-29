# frozen_string_literal: true

class Llm::CaptainResponseContentNormalizer
  SCHEMA_NAME = 'Captain::ResponseSchema'
  SUGGESTION_SCHEMA_NAME = 'Captain::SuggestionResponseSchema'
  SCHEMA_NAMES = [SCHEMA_NAME, SUGGESTION_SCHEMA_NAME].freeze
  DEFAULT_REASONING = 'Response generated from the current conversation and available tool results.'
  INVALID_PUBLIC_RESPONSE_LITERALS = %w[true false null response].freeze
  RETIRED_HANDOFF_KEYS = %w[handoff_message handoff_reason].freeze
  CURLY_APOSTROPHES = /[\u2018\u2019\u02BC]/
  CURLY_QUOTES = /[\u201C\u201D]/
  REFUSAL_LEAD_IN = '(?:as\s+an\s+ai(?:\s+(?:assistant|language\s+model|model))?,?\s*)?' \
                    "(?:(?:i'm\\s+sorry|i\\s+am\\s+sorry|sorry|i\\s+apologize)(?:,?\\s+but)?\\s*,?\\s*)?"
  REFUSAL_SUBJECT_VERB = "(?:i\\s+(?:cannot|can't|am\\s+unable\\s+to|am\\s+not\\s+able\\s+to|won't|will\\s+not)|" \
                         "i'm\\s+(?:unable|not\\s+able)\\s+to)"
  REFUSAL_ACTION = '(?:assist|help|fulfill|comply|complete|process|answer|respond|provide|generate|continue|engage)'
  REFUSAL_TARGET = '(?:\s+you)?(?:\s+(?:with|to))?\s+' \
                   '(?:that|this|it|(?:that|this|your|such)\s+(?:request|requests|query|topic|prompt|conversation|content|matter))'
  REFUSAL_TRAILER = '(?:[.!]+(?:\s+(?:if\s+you\s+have\s+(?:any\s+)?other\s+questions|feel\s+free\s+to\s+ask|' \
                    "i(?:'m|\\s+am)\\s+here\\s+to\\s+help)[^.!?]*[.!]?)?|[.!]*)"
  PROVIDER_REFUSAL_PATTERNS = [
    /\A#{REFUSAL_LEAD_IN}#{REFUSAL_SUBJECT_VERB}\s+#{REFUSAL_ACTION}#{REFUSAL_TARGET}#{REFUSAL_TRAILER}\z/i
  ].freeze

  class << self
    def apply_defaults(schema, content)
      return content unless applicable?(schema)
      return content unless content.respond_to?(:with_indifferent_access)

      payload = content.with_indifferent_access
      # Outcome reasons belong to the classification pipeline.
      payload.delete('handoff_status_reason')
      payload.delete('handoff_outcome_reason_id')
      # The model is no longer asked for the handoff text or reason (the handoff tool and the platform write them), and the strict
      # schema rejects unknown keys: drop what an older prompt, a cached reply or a provider still sends.
      RETIRED_HANDOFF_KEYS.each { |key| payload.delete(key) }
      payload['response_mode'] = normalized_response_mode(payload['response_mode'])
      # The language is for the logs and the reply is delivered whatever it says: a missing one is blank, never a rejected reply.
      apply_text_default!(payload, 'patient_language')
      apply_text_default!(payload, 'operator_note') if suggestion_schema?(schema)
      apply_reasoning_default!(payload)
      payload['artifact_ids'] = normalized_artifact_ids(payload['artifact_ids'])
      payload
    end

    def plain_text_fallback(schema, content)
      return unless applicable?(schema)
      return unless content.is_a?(String)

      text = strip_provider_reasoning(content)
      return if unusable_plain_text_fallback?(text)

      fallback = {
        patient_language: '',
        response: text,
        response_mode: 'reply',
        reasoning: DEFAULT_REASONING,
        artifact_ids: []
      }
      suggestion_schema?(schema) ? fallback.merge(operator_note: '') : fallback
    end

    def applicable?(schema)
      SCHEMA_NAMES.include?(Llm::StructuredOutputSchema.name_for(schema))
    end

    def suggestion_schema?(schema)
      Llm::StructuredOutputSchema.name_for(schema) == SUGGESTION_SCHEMA_NAME
    end

    def normalize_quotes(value)
      value.to_s.gsub(CURLY_APOSTROPHES, "'").gsub(CURLY_QUOTES, '"')
    end

    def provider_refusal?(value)
      return false unless value.is_a?(String)

      stripped = strip_provider_reasoning(value)
      stripped = Captain::PromptClock.unstamped(stripped) if defined?(Captain::PromptClock)
      cleaned = normalize_quotes(stripped).squish
      return false if cleaned.blank?

      PROVIDER_REFUSAL_PATTERNS.any? { |pattern| pattern.match?(cleaned) }
    end

    def invalid_public_response?(value)
      return true unless value.is_a?(String)

      INVALID_PUBLIC_RESPONSE_LITERALS.include?(value.strip.downcase) || provider_refusal?(value)
    end

    def invalid_public_response_message(value)
      "Model output returned invalid public response #{value.inspect}"
    end

    private

    def unusable_plain_text_fallback?(text)
      text.blank? || invalid_public_response?(text) || json_document_like?(text) || Llm::JsonDocumentExtractor.call(text).present?
    end

    def normalized_response_mode(value)
      value.to_s.strip.presence || 'reply'
    end

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
