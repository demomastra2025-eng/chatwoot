class Captain::ToolTraceBuilder
  VERSION = 1
  TYPE = 'captain_tool_event'.freeze
  PREVIEW_LIMIT = 4000
  START_STATUSES = %w[start progress].freeze
  TERMINAL_SUCCESS_STATUSES = %w[finish].freeze
  TERMINAL_FAILURE_STATUSES = %w[failed].freeze
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
      'tool_call_id' => options[:tool_call_id],
      'input' => safe_payload(options[:input]),
      'output' => safe_payload(options[:output]),
      'error' => safe_payload(options[:error]),
      'mutation' => options[:mutation],
      'idempotency_key' => options[:idempotency_key],
      'current_agent' => options[:current_agent],
      'openrouter_generation_id' => options[:openrouter_generation_id],
      'started_at' => options[:started_at],
      'finished_at' => options[:finished_at],
      'completed_at' => options[:completed_at] || options[:finished_at],
      'duration_ms' => options[:duration_ms]
    }.compact
  end

  def self.payload(steps = nil, **reasoning_options)
    normalized_steps = Array(steps).compact
    reasoning_payload = normalized_reasoning_payload(reasoning_options)
    return if normalized_steps.blank? && reasoning_payload.blank?

    {
      'version' => VERSION,
      'tool_steps' => normalized_steps.presence,
      'tool_calls' => tool_calls(normalized_steps).presence
    }.merge(reasoning_payload).compact
  end

  def self.tool_calls(steps)
    groups = []
    groups_by_call_id = {}
    active_groups_by_tool_name = {}

    Array(steps).compact.each_with_index do |step, index|
      normalized_step = step.respond_to?(:to_h) ? step.to_h.with_indifferent_access : {}
      next if normalized_step.blank?

      tool_name = normalized_step[:tool_name].presence || normalized_step[:toolName].presence || 'tool'
      status = normalized_step[:status].to_s.presence || STATUS_BY_EVENT.fetch(normalized_step[:event].to_s, 'progress')
      tool_call_id = normalized_step[:tool_call_id].presence || tool_call_id_from_step_id(normalized_step, tool_name)
      group_key = tool_call_id.present? ? "#{tool_name}:#{tool_call_id}" : nil
      group = nil

      if group_key.present?
        group = groups_by_call_id[group_key]
        unless group
          group = new_tool_call_group(normalized_step, index, tool_name, tool_call_id)
          groups_by_call_id[group_key] = group
          groups << group
        end
      elsif START_STATUSES.include?(status)
        group = new_tool_call_group(normalized_step, index, tool_name, nil)
        active_groups_by_tool_name[tool_name] = group
        groups << group
      else
        group = active_groups_by_tool_name[tool_name] ||
                new_tool_call_group(normalized_step, index, tool_name, nil).tap { |new_group| groups << new_group }
      end

      merge_step_into_tool_call!(group, normalized_step)

      next unless terminal_status?(group['status'])

      groups_by_call_id.delete(group_key) if group_key.present?
      active_groups_by_tool_name.delete(tool_name) if active_groups_by_tool_name[tool_name].equal?(group)
    end

    groups.each do |group|
      group['status'] = 'partial' unless terminal_group?(group)
    end
  end

  def self.tool_call_id_from_step_id(step, tool_name)
    id = step[:id].to_s
    parts = id.split(':')
    return if parts.length < 4

    step_event = step[:event].to_s
    step_sequence = parts[2]
    return if parts[0] != tool_name.to_s || parts[1] != step_event || step_sequence.blank?

    parts[3..].join(':').presence
  end
  private_class_method :tool_call_id_from_step_id

  def self.new_tool_call_group(step, index, tool_name, tool_call_id)
    {
      'tool_call_id' => tool_call_id || step[:tool_call_id] || "trace-#{index + 1}",
      'tool_name' => tool_name,
      'status' => normalized_group_status(step[:status]),
      'started_at' => step[:started_at],
      'completed_at' => step[:completed_at] || step[:finished_at],
      'duration_ms' => step[:duration_ms],
      'input' => step[:input],
      'output' => step[:output],
      'error' => step[:error],
      'mutation' => step[:mutation],
      'idempotency_key' => step[:idempotency_key],
      'current_agent' => step[:current_agent],
      'openrouter_generation_id' => step[:openrouter_generation_id]
    }.compact
  end
  private_class_method :new_tool_call_group

  def self.merge_step_into_tool_call!(group, step)
    group['status'] = normalized_group_status(step[:status])
    group['started_at'] ||= step[:started_at]
    group['completed_at'] = step[:completed_at] || step[:finished_at] || group['completed_at']
    group['duration_ms'] = step[:duration_ms] if step[:duration_ms].present?
    group['input'] ||= step[:input] if step.key?(:input)
    group['output'] = step[:output] if step.key?(:output)
    group['error'] = step[:error] if step.key?(:error)
    group['mutation'] = step[:mutation] unless step[:mutation].nil?
    group['idempotency_key'] ||= step[:idempotency_key]
    group['current_agent'] ||= step[:current_agent]
    group['openrouter_generation_id'] ||= step[:openrouter_generation_id]
    group.compact!
  end
  private_class_method :merge_step_into_tool_call!

  def self.normalized_group_status(status)
    normalized = status.to_s
    return 'completed' if TERMINAL_SUCCESS_STATUSES.include?(normalized)
    return 'failed' if TERMINAL_FAILURE_STATUSES.include?(normalized)
    return 'started' if START_STATUSES.include?(normalized)
    return 'suppressed' if normalized == 'suppressed'

    normalized.presence || 'partial'
  end
  private_class_method :normalized_group_status

  def self.terminal_status?(status)
    %w[completed failed suppressed].include?(status.to_s)
  end
  private_class_method :terminal_status?

  def self.terminal_group?(group)
    terminal_status?(group['status'])
  end
  private_class_method :terminal_group?

  def self.normalized_reasoning_payload(options)
    {
      'reasoning' => options[:reasoning],
      'native_reasoning' => options[:native_reasoning],
      'structured_reasoning' => options[:structured_reasoning],
      'system_fallback_reason' => options[:system_fallback_reason]
    }.transform_values { |value| value.present? ? safe_payload(value) : nil }.compact
  end
  private_class_method :normalized_reasoning_payload

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
