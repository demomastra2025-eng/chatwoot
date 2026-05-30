class Captain::ToolTraceBuilder
  VERSION = 1
  TYPE = 'captain_tool_event'.freeze
  PREVIEW_LIMIT = 4000
  SENSITIVE_KEY_PATTERN = /token|secret|password|authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|credential|cookie|phone|телефон/i
  STATUS_BY_EVENT = {
    'start' => 'start',
    'progress' => 'progress',
    'finish' => 'finish',
    'complete' => 'finish',
    'failed' => 'failed',
    'error' => 'failed'
  }.freeze
  EVENT_MESSAGES = {
    'start' => 'Using %<tool_name>s',
    'progress' => 'Running %<tool_name>s',
    'finish' => 'Completed %<tool_name>s',
    'complete' => 'Completed %<tool_name>s',
    'failed' => 'Failed %<tool_name>s',
    'error' => 'Failed %<tool_name>s'
  }.freeze

  def self.step(tool_name:, event:, sequence:, **options)
    normalized_tool_name = tool_name.to_s
    normalized_event = event.to_s
    normalized_status = STATUS_BY_EVENT.fetch(normalized_event, normalized_event)
    id_parts = [normalized_tool_name, normalized_event, sequence]
    id_parts << options[:tool_call_id] if options[:tool_call_id].present?

    {
      'id' => id_parts.join(':'),
      'type' => TYPE,
      'tool_name' => normalized_tool_name,
      'event' => normalized_event,
      'status' => normalized_status,
      'content' => options[:message].presence || format(EVENT_MESSAGES.fetch(normalized_event, EVENT_MESSAGES.fetch(normalized_status)),
                                                        tool_name: normalized_tool_name),
      'input' => safe_payload(options[:input]),
      'output' => safe_payload(options[:output]),
      'error' => safe_payload(options[:error]),
      'started_at' => options[:started_at],
      'finished_at' => options[:finished_at],
      'duration_ms' => options[:duration_ms]
    }.compact
  end

  def self.payload(steps = nil, reasoning: nil)
    normalized_steps = Array(steps).compact
    normalized_reasoning = reasoning.present? ? safe_payload(reasoning) : nil
    return if normalized_steps.blank? && normalized_reasoning.blank?

    {
      'version' => VERSION,
      'tool_steps' => normalized_steps.presence,
      'reasoning' => normalized_reasoning
    }.compact
  end

  def self.safe_payload(value)
    return if value.nil?

    truncate_payload(redact_payload(Captain::EncodingNormalizer.utf8(value)))
  rescue StandardError
    truncate_payload(redact_payload(value.to_s))
  end
  private_class_method :safe_payload

  def self.redact_payload(value)
    return redact_hash(value) if value.is_a?(Hash)
    return value.map { |item| redact_payload(item) } if value.is_a?(Array)
    return redact_string("#{value.class.name}: #{value.message}") if value.is_a?(StandardError)
    return redact_string(value) if value.is_a?(String)

    value
  end
  private_class_method :redact_payload

  def self.redact_hash(value)
    value.each_with_object({}) do |(key, child_value), memo|
      normalized_key = key.to_s
      memo[normalized_key] = sensitive_key?(normalized_key) ? '[REDACTED]' : redact_payload(child_value)
    end
  end
  private_class_method :redact_hash

  def self.sensitive_key?(key)
    key.match?(SENSITIVE_KEY_PATTERN)
  end
  private_class_method :sensitive_key?

  def self.redact_string(value)
    value
      .gsub(/Bearer\s+[A-Za-z0-9._\-]+/, 'Bearer [REDACTED]')
      .gsub(/(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password)=([^\s&]+)/i, '\\1=[REDACTED]')
  end
  private_class_method :redact_string

  def self.truncate_payload(value)
    case value
    when Hash
      value.transform_values { |child_value| truncate_payload(child_value) }
    when Array
      value.map { |item| truncate_payload(item) }
    when String
      value.bytesize > PREVIEW_LIMIT ? "#{value.byteslice(0, PREVIEW_LIMIT)}…" : value
    else
      value
    end
  end
  private_class_method :truncate_payload
end
