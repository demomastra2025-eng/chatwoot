# frozen_string_literal: true

class Telephony::AiVoice::TranscriptItemNormalizer
  CAPTAIN_PAYLOAD_KEYS = %w[
    response
    reasoning
    reasoning_summary
    artifact_ids
    handoff_message
    handoff_reason
    handoff_status_reason
  ].freeze
  PRESENTATION_INTERNAL_KEYS = %w[
    raw_text
    structured_response
    reasoning
    artifact_ids
    handoff_message
    handoff_reason
    handoff_status_reason
    normalized_from
  ].freeze
  HANDOFF_LITERAL = 'conversation_handoff'
  DEFAULT_HANDOFF_MESSAGE = 'Сейчас соединю вас со специалистом.'
  DEFAULT_EMPTY_RESPONSE = 'Понял.'

  def self.call(item)
    new(item).call
  end

  def self.presentation_item(item)
    new(item).presentation_item
  end

  def initialize(item)
    @item = (item || {}).deep_stringify_keys
  end

  def call
    normalized = normalized_item
    return normalized unless normalized['speaker'].to_s == 'ai'
    return normalized if normalized['text'].blank?

    payload = parsed_captain_payload(normalized['text'])
    return normalized if payload.blank?

    response = visible_response(payload)
    return normalized if response.blank? && !captain_payload?(payload)

    apply_captain_payload(normalized, payload, response)
  end

  def presentation_item
    call.except(*PRESENTATION_INTERNAL_KEYS).compact
  end

  private

  def normalized_item
    normalized = @item.deep_dup
    normalized['text'] = normalized['text'].to_s.strip
    normalized
  end

  def apply_captain_payload(normalized, payload, response)
    normalized.merge(captain_payload_attributes(normalized['text'], payload, response)).compact
  end

  def captain_payload_attributes(raw_text, payload, response)
    {
      'raw_text' => raw_text,
      'text' => response.presence || DEFAULT_EMPTY_RESPONSE,
      'reasoning' => normalized_text(payload['reasoning'] || payload['reasoning_summary']),
      'artifact_ids' => normalized_artifact_ids(payload['artifact_ids']),
      'handoff_message' => normalized_text(payload['handoff_message']),
      'handoff_reason' => normalized_text(payload['handoff_reason']),
      'handoff_status_reason' => normalized_text(payload['handoff_status_reason']),
      'structured_response' => structured_response(payload),
      'normalized_from' => 'captain_json_response'
    }
  end

  def parsed_captain_payload(text)
    document = Llm::JsonDocumentExtractor.call(text)
    return if document.blank?

    payload = JSON.parse(document)
    return unless payload.is_a?(Hash)

    payload.deep_stringify_keys
  rescue JSON::ParserError
    nil
  end

  def captain_payload?(payload)
    CAPTAIN_PAYLOAD_KEYS.any? { |key| payload.key?(key) }
  end

  def visible_response(payload)
    response = normalized_text(payload['response'] || payload['message'] || payload['content'] || payload['answer'])
    return normalized_text(payload['handoff_message']).presence || DEFAULT_HANDOFF_MESSAGE if response == HANDOFF_LITERAL

    response
  end

  def normalized_text(value)
    text = value.to_s.strip
    text.presence
  end

  def normalized_artifact_ids(value)
    Array.wrap(value).filter_map { |item| normalized_text(item) }.presence
  end

  def structured_response(payload)
    payload.slice(*CAPTAIN_PAYLOAD_KEYS).compact
  end
end
