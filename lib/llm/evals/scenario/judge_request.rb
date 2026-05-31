# frozen_string_literal: true

class Llm::Evals::Scenario::JudgeRequest
  SENSITIVE_KEY_PATTERN = /token|secret|password|authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|credential|cookie/i

  RESPONSE_SCHEMA = {
    type: 'object',
    required: %w[verdict reasoning],
    properties: {
      verdict: { type: 'string', enum: %w[success failure continue inconclusive] },
      reasoning: { type: 'string' },
      passed_criteria: { type: 'array', items: { type: 'string' } },
      failed_criteria: { type: 'array', items: { type: 'string' } }
    }
  }.freeze

  TRACE_TOOL_SCHEMAS = [
    {
      name: 'expand_trace',
      description: 'Return sanitized trace events by index or event name.',
      parameters: {
        type: 'object',
        properties: { index: { type: 'integer' }, event_name: { type: 'string' }, limit: { type: 'integer' } }
      }
    },
    {
      name: 'grep_trace',
      description: 'Search sanitized trace events for a text fragment.',
      parameters: {
        type: 'object',
        required: ['query'],
        properties: {
          query: { type: 'string' },
          fields: { type: 'array', items: { type: 'string' } },
          limit: { type: 'integer' }
        }
      }
    }
  ].freeze

  def initialize(**attributes)
    @input = attributes.fetch(:input)
    @criteria = attributes.fetch(:criteria)
    @expected = attributes.fetch(:expected)
    @deterministic_failures = attributes.fetch(:deterministic_failures)
    @trace_events = attributes[:trace_events]
  end

  def call
    {
      thread_id: @input.thread_id,
      criteria: @criteria,
      expected: @expected.presence,
      deterministic_failures: @deterministic_failures,
      messages: compact_messages(@input.messages),
      new_messages: compact_messages(@input.new_messages),
      tool_events: compact_tool_events(@input.state.tool_events),
      state_summary: compact_state_summary(@input.state.summary),
      trace_digest: trace_digest,
      response_schema: RESPONSE_SCHEMA,
      tools: TRACE_TOOL_SCHEMAS
    }.compact
  end

  private

  def compact_messages(messages)
    Array(messages).map do |message|
      attributes = message.to_h.deep_symbolize_keys
      attributes.slice(:role, :content, :reasoning, :tool_name, :status, :_index).compact
    end
  end

  def compact_tool_events(tool_events)
    Array(tool_events).map do |event|
      attributes = event.to_h.deep_symbolize_keys
      sanitize_value(attributes.slice(:action, :tool_name, :status, :input, :arguments, :result, :output, :error, :_index).compact)
    end
  end

  def compact_state_summary(summary)
    summary.to_h.deep_symbolize_keys.except(:messages, :tool_events)
  end

  def trace_digest
    events = @trace_events || Array(@input.trace_events).presence || @input.state.events
    Llm::Evals::TraceDigest.new(events: events).call
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

  def sensitive_key?(key)
    key.to_s.match?(SENSITIVE_KEY_PATTERN)
  end

  def redact_string(value)
    value
      .gsub(/Bearer\s+[A-Za-z0-9._\-]+/, 'Bearer [REDACTED]')
      .gsub(/(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password)=([^\s&]+)/i, '\\1=[REDACTED]')
  end
end
