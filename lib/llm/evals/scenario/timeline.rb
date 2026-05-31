# frozen_string_literal: true

class Llm::Evals::Scenario::Timeline
  PREVIEW_KEYS = %i[content text response result output error reasoning].freeze
  SENSITIVE_FRAGMENT = /(api[_-]?key|token|secret|password|authorization|credential)(=|:)?[^\s,;&]*/i
  MAX_PREVIEW_LENGTH = 240

  def initialize(state:)
    @state = state
  end

  def call
    Array(@state&.events).map { |event| timeline_entry(event.to_h.deep_symbolize_keys) }
  end

  private

  def timeline_entry(event)
    {
      index: event[:_index],
      type: event_type(event),
      role: event[:role],
      action: event[:action],
      tool_name: event[:tool_name],
      status: event[:status],
      verdict: event[:verdict] || event.dig(:details, :verdict),
      duration_ms: event[:duration_ms],
      preview: preview_for(event)
    }.compact
  end

  def event_type(event)
    return 'message' if event[:role].present?
    return 'tool' if event[:action].to_s.start_with?('tool_')
    return 'judge' if event[:action].to_s == 'judge_evaluation'

    'event'
  end

  def preview_for(event)
    raw_value = PREVIEW_KEYS.filter_map { |key| event[key] }.first
    return if raw_value.blank?

    text = raw_value.is_a?(String) ? raw_value : raw_value.to_json
    redact(text)
  end

  def redact(value)
    redacted = value.gsub(SENSITIVE_FRAGMENT) do |match|
      key = match.split(/=|:/, 2).first
      "#{key}=[REDACTED]"
    end

    return redacted if redacted.length <= MAX_PREVIEW_LENGTH

    "#{redacted[0, MAX_PREVIEW_LENGTH]}..."
  end
end
