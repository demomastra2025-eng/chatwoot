# frozen_string_literal: true

class Llm::Monitoring::OtelEventExporter
  ENV_ENABLED_KEY = 'LLM_EVENT_OTEL_EXPORT_ENABLED'
  ENV_SAMPLE_RATE_KEY = 'LLM_EVENT_OTEL_SAMPLE_RATE'
  CONFIG_ENABLED_KEY = 'LLM_EVENT_OTEL_EXPORT_ENABLED'
  DEFAULT_SAMPLE_RATE = 1.0

  GEN_AI_ATTRIBUTES = {
    'provider' => 'gen_ai.provider.name',
    'model' => 'gen_ai.request.model',
    'prompt_tokens' => 'gen_ai.usage.input_tokens',
    'input_tokens' => 'gen_ai.usage.input_tokens',
    'completion_tokens' => 'gen_ai.usage.output_tokens',
    'output_tokens' => 'gen_ai.usage.output_tokens',
    'total_tokens' => 'gen_ai.usage.total_tokens',
    'error_code' => 'gen_ai.response.error_code'
  }.freeze

  ONE_LINK_ATTRIBUTES = {
    'canonical_event_name' => 'one_link.event.name',
    'event_name_alias' => 'one_link.event.alias',
    'request_id' => 'one_link.request_id',
    'trace_id' => 'one_link.trace_id',
    'session_id' => 'one_link.session_id',
    'account_id' => 'one_link.account_id',
    'assistant_id' => 'one_link.assistant_id',
    'conversation_id' => 'one_link.conversation_id',
    'conversation_display_id' => 'one_link.conversation_display_id',
    'copilot_thread_id' => 'one_link.copilot_thread_id',
    'feature' => 'one_link.feature',
    'runtime_mode' => 'one_link.runtime_mode',
    'project_case_id' => 'one_link.project_case_id',
    'tool_name' => 'one_link.tool.name',
    'schema_name' => 'one_link.schema.name',
    'status' => 'one_link.status',
    'reason' => 'one_link.reason',
    'source' => 'one_link.source',
    'channel_type' => 'one_link.channel_type',
    'current_agent' => 'one_link.current_agent',
    'queue_wait_ms' => 'one_link.queue_wait_ms',
    'thinking_tokens' => 'one_link.thinking_tokens',
    'payload_bytes' => 'one_link.payload_bytes',
    'payload_truncated' => 'one_link.payload_truncated',
    'retry_count' => 'one_link.retry_count',
    'tool_calls_count' => 'one_link.tool_calls_count',
    'schema_invalid_count' => 'one_link.schema_invalid_count'
  }.freeze

  RAW_CONTENT_KEYS = %w[
    prompt prompts messages input output response content text body args arguments result results tool_result image_url
  ].freeze

  class << self
    def export_notification(event_name:, started_at:, finished_at:, payload:)
      return unless enabled?
      return unless sampled?

      new(event_name: event_name, started_at: started_at, finished_at: finished_at, payload: payload).export
    rescue StandardError => e
      Rails.logger.warn("[Llm::Monitoring::OtelEventExporter] Failed to export #{event_name}: #{e.class}: #{e.message}")
      nil
    end

    def enabled?
      ChatwootApp.otel_enabled? && enabled_config?
    rescue StandardError
      false
    end

    private

    def enabled_config?
      enabled_value = ENV.fetch(ENV_ENABLED_KEY, nil).presence || installation_config_value(CONFIG_ENABLED_KEY)
      ActiveModel::Type::Boolean.new.cast(enabled_value)
    end

    def installation_config_value(name)
      InstallationConfig.find_by(name: name)&.value
    rescue StandardError
      nil
    end

    def sampled?
      sample_rate >= DEFAULT_SAMPLE_RATE || rand < sample_rate
    end

    def sample_rate
      value = ENV.fetch(ENV_SAMPLE_RATE_KEY, nil).presence
      return DEFAULT_SAMPLE_RATE if value.blank?

      Float(value).clamp(0.0, 1.0)
    rescue ArgumentError, TypeError
      0.0
    end
  end

  def initialize(event_name:, started_at:, finished_at:, payload:)
    @event_name = event_name.to_s
    @started_at = started_at
    @finished_at = finished_at
    @payload = payload.to_h.stringify_keys
  end

  def export
    OpentelemetryConfig.tracer.in_span(span_name) do |span|
      export_attributes(span, safe_attributes)
    end
  end

  private

  def span_name
    @payload['canonical_event_name'].presence || @event_name
  end

  def safe_attributes
    attributes = { 'one_link.event.name' => span_name }
    attributes['one_link.event.duration_ms'] = duration_ms if duration_ms.present?

    GEN_AI_ATTRIBUTES.each do |payload_key, attribute_name|
      attributes[attribute_name] ||= @payload[payload_key] if exportable?(@payload[payload_key])
    end

    ONE_LINK_ATTRIBUTES.each do |payload_key, attribute_name|
      attributes[attribute_name] = @payload[payload_key] if exportable?(@payload[payload_key])
    end

    attributes.compact
  end

  def export_attributes(span, attributes)
    attributes.each do |name, value|
      next if raw_content_attribute?(name)

      span.set_attribute(name, normalize_attribute_value(value))
    end
  end

  def raw_content_attribute?(name)
    name.to_s.match?(/(?:prompt|messages|content|body|arguments|result|image_url)/)
  end

  def exportable?(value)
    return false if value.nil?
    return false if value.respond_to?(:blank?) && value.blank?

    true
  end

  def normalize_attribute_value(value)
    return value if value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false

    value.to_s
  end

  def duration_ms
    return unless @started_at && @finished_at

    ((@finished_at - @started_at) * 1000).round
  rescue StandardError
    nil
  end
end
