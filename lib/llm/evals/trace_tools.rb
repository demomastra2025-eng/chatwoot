# frozen_string_literal: true

class Llm::Evals::TraceTools
  DEFAULT_LIMIT = 10

  def initialize(events:)
    @events = Array(events)
  end

  def expand_trace(index: nil, event_name: nil, limit: DEFAULT_LIMIT)
    filtered = normalized_events
    filtered = filtered.select { |event| event[:index].to_i == index.to_i } if index.present?
    filtered = filtered.select { |event| event[:event_name].to_s == event_name.to_s } if event_name.present?

    filtered.first(normalized_limit(limit))
  end

  def grep_trace(query:, fields: nil, limit: DEFAULT_LIMIT)
    needle = query.to_s.downcase
    return [] if needle.blank?

    normalized_events.select do |event|
      searchable_text(event, fields).include?(needle)
    end.first(normalized_limit(limit))
  end

  private

  def normalized_events
    @normalized_events ||= Llm::Evals::TraceDigest.new(events: @events, max_events: @events.size).call.fetch(:events)
  end

  def searchable_text(event, fields)
    selected_fields = Array(fields).presence&.map(&:to_sym)
    values = selected_fields.present? ? selected_fields.filter_map { |field| event[field] } : [event]

    values.map { |value| value.is_a?(String) ? value : value.to_json }.join(' ').downcase
  end

  def normalized_limit(limit)
    normalized = limit.to_i
    normalized.positive? ? [normalized, 100].min : DEFAULT_LIMIT
  end
end
