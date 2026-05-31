# frozen_string_literal: true

class Llm::Evals::TraceDigest
  DEFAULT_MAX_EVENTS = 50
  DEFAULT_MAX_PAYLOAD_BYTES = 2_000
  TOKEN_USAGE_KEYS = %w[
    cached_tokens completion_tokens input_tokens output_tokens prompt_tokens reasoning_tokens thinking_tokens token_count total_tokens
  ].freeze
  SENSITIVE_KEY_PATTERN = /token|secret|password|authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|credential|cookie/i

  def initialize(events:, max_events: DEFAULT_MAX_EVENTS, max_payload_bytes: DEFAULT_MAX_PAYLOAD_BYTES)
    @events = Array(events)
    @max_events = max_events.to_i.positive? ? max_events.to_i : DEFAULT_MAX_EVENTS
    @max_payload_bytes = max_payload_bytes.to_i.positive? ? max_payload_bytes.to_i : DEFAULT_MAX_PAYLOAD_BYTES
  end

  def call
    normalized_events = @events.map.with_index { |event, index| normalize_event(event, index) }

    {
      total_count: normalized_events.size,
      included_count: included_events(normalized_events).size,
      counts_by_event_name: normalized_events.pluck(:event_name).compact_blank.tally,
      tool_names: normalized_events.pluck(:tool_name).compact_blank.uniq,
      error_count: normalized_events.count { |event| event[:error] },
      schema_invalid_count: normalized_events.count { |event| event[:schema_invalid] },
      openrouter_generation_ids: generation_ids(normalized_events),
      token_totals: token_totals(normalized_events),
      estimated_cost: estimated_cost(normalized_events),
      events: included_events(normalized_events)
    }
  end

  private

  def included_events(normalized_events)
    normalized_events.first(@max_events)
  end

  def normalize_event(event, index)
    attributes = event_attributes(event)
    payload = sanitized_payload(attributes[:payload])

    base_event_attributes(index, attributes)
      .merge(runtime_event_attributes(attributes, payload))
      .merge(token_event_attributes(attributes, payload))
      .merge(payload: payload.presence)
      .compact
  end

  def base_event_attributes(index, attributes)
    {
      index: index,
      id: attributes[:id],
      event_name: attributes[:event_name] || attributes[:name] || attributes[:action],
      created_at: timestamp(attributes[:created_at]),
      feature: attributes[:feature],
      runtime_mode: attributes[:runtime_mode]
    }
  end

  def runtime_event_attributes(attributes, payload)
    {
      provider: value_attribute(attributes, payload, :provider),
      model: value_attribute(attributes, payload, :model),
      status: value_attribute(attributes, payload, :status),
      error: truthy?(value_attribute(attributes, payload, :error)),
      schema_invalid: truthy?(value_attribute(attributes, payload, :schema_invalid)),
      tool_name: value_attribute(attributes, payload, :tool_name),
      openrouter_generation_id: value_attribute(attributes, payload, :openrouter_generation_id)
    }
  end

  def token_event_attributes(attributes, payload)
    {
      prompt_tokens: integer_attribute(attributes, payload, :prompt_tokens),
      completion_tokens: integer_attribute(attributes, payload, :completion_tokens),
      thinking_tokens: integer_attribute(attributes, payload, :thinking_tokens),
      total_tokens: integer_attribute(attributes, payload, :total_tokens),
      estimated_cost: decimal_attribute(attributes, payload, :estimated_cost)
    }
  end

  def integer_attribute(attributes, payload, key)
    integer_value(value_attribute(attributes, payload, key))
  end

  def decimal_attribute(attributes, payload, key)
    decimal_value(value_attribute(attributes, payload, key))
  end

  def value_attribute(attributes, payload, key)
    attributes[key].presence || payload[key]
  end

  def event_attributes(event)
    if event.respond_to?(:attributes)
      event.attributes.deep_symbolize_keys
    elsif event.respond_to?(:to_h)
      event.to_h.deep_symbolize_keys
    else
      {}
    end
  end

  def sanitized_payload(payload)
    sanitized = sanitize_value(payload.to_h.deep_symbolize_keys)
    truncate_payload(sanitized)
  rescue StandardError
    {}
  end

  def sanitize_value(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, child_value), result|
        result[key] = sensitive_key?(key) ? '[REDACTED]' : sanitize_value(child_value)
      end
    when Array
      value.map { |child_value| sanitize_value(child_value) }
    when String
      redact_string(value)
    else
      value
    end
  end

  def truncate_payload(payload)
    json = payload.to_json
    return payload if json.bytesize <= @max_payload_bytes

    { truncated: true, bytes: json.bytesize, preview: json.byteslice(0, @max_payload_bytes) }
  end

  def sensitive_key?(key)
    key_string = key.to_s
    TOKEN_USAGE_KEYS.exclude?(key_string) && key_string.match?(SENSITIVE_KEY_PATTERN)
  end

  def redact_string(value)
    value
      .gsub(/Bearer\s+[A-Za-z0-9._\-]+/, 'Bearer [REDACTED]')
      .gsub(/(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password)=([^\s&]+)/i, '\\1=[REDACTED]')
  end

  def timestamp(value)
    return value.iso8601 if value.respond_to?(:iso8601)

    value
  end

  def truthy?(value)
    value == true || value.to_s == 'true'
  end

  def integer_value(value)
    Integer(value) if value.present?
  rescue ArgumentError, TypeError
    nil
  end

  def generation_ids(events)
    events.pluck(:openrouter_generation_id).compact_blank.uniq
  end

  def token_totals(events)
    %i[prompt_tokens completion_tokens thinking_tokens total_tokens].index_with do |key|
      events.sum { |event| event[key].to_i }
    end.compact
  end

  def estimated_cost(events)
    cost = events.sum { |event| decimal_value(event[:estimated_cost]) || BigDecimal(0) }
    cost.positive? ? cost.to_f.round(8) : nil
  end

  def decimal_value(value)
    BigDecimal(value.to_s) if value.present?
  rescue ArgumentError, TypeError
    nil
  end
end
