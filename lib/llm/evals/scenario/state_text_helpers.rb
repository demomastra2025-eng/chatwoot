# frozen_string_literal: true

module Llm::Evals::Scenario::StateTextHelpers
  TEXT_KEYS = %i[content text transcript result output response arguments].freeze
  GENERATION_ID_KEYS = %i[openrouter_generation_id generation_id].freeze

  private

  def text_entries_for_role(role)
    messages.filter_map do |message|
      next unless message[:role].to_s == role.to_s

      text = event_text(message)
      next if text.blank?

      { index: message[:_index].to_i, text: text }
    end
  end

  def normalize_payload(payload)
    case payload
    when Hash
      payload.deep_symbolize_keys
    else
      { content: payload.to_s }
    end
  end

  def mutating_tool_events
    tool_events.select { |event| mutating_tool_event?(event) }
  end

  def mutating_tool_event?(event)
    event[:mutation] == true ||
      event[:mutating] == true ||
      event[:mutation].to_s == 'true' ||
      event[:mutating].to_s == 'true'
  end

  def mutation_identity(event)
    idempotency_key = event[:idempotency_key].to_s.presence
    return "idempotency:#{idempotency_key}" if idempotency_key

    parts = [event[:tool_name], event[:resource_type], event[:resource_id]].map { |part| part.to_s.presence }
    return nil if parts.all?(&:blank?)

    parts.join(':')
  end

  def collect_generation_ids(value)
    case value
    when Hash
      value.flat_map do |key, child_value|
        matches = GENERATION_ID_KEYS.include?(key.to_sym) ? [child_value] : []
        matches + collect_generation_ids(child_value)
      end
    when Array
      value.flat_map { |child_value| collect_generation_ids(child_value) }
    else
      []
    end
  end

  def text_includes?(text, fragment)
    text = text.to_s
    fragment = fragment.to_s
    return true if text.include?(fragment)

    compact_text = text.gsub(/[[:space:]]/, '')
    compact_fragment = fragment.gsub(/[[:space:]]/, '')
    compact_fragment.present? && compact_text.include?(compact_fragment)
  end
end
