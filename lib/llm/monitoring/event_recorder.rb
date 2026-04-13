# frozen_string_literal: true

require 'set'

class Llm::Monitoring::EventRecorder
  PERSISTED_EVENTS = Set.new(
    %w[
      llm.agent.handoff
      llm.chat.complete
      llm.embedding.complete
      llm.moderation.complete
      llm.moderation.unavailable
      llm.run.complete
      llm.safety.blocked
      llm.schema.invalid
      llm.schema.repair_requested
      llm.transcription.complete
      llm.tool.complete
    ]
  ).freeze

  PROMOTED_PAYLOAD_KEYS = Set.new(
    %w[
      account_id assistant_id blocked channel_type completion_tokens conversation_display_id
      conversation_id copilot_thread_id current_agent error estimated_cost feature model
      moderation_skipped prompt_tokens provider reason request_id runtime_mode
      schema_invalid schema_name session_id source status tool_failure tool_name
      total_tokens trace_id
    ]
  ).freeze

  class << self
    def record_notification(**args)
      new(**args).record
    end
  end

  def initialize(event_name:, started_at:, finished_at:, payload:)
    @event_name = event_name.to_s
    @started_at = started_at
    @finished_at = finished_at
    @payload = Llm::Monitoring::PayloadSanitizer.call(payload.to_h.stringify_keys)
  end

  def record
    return unless PERSISTED_EVENTS.include?(@event_name)

    LlmEvent.create!(event_attributes)
  rescue StandardError => e
    Rails.logger.warn("[Llm::Monitoring::EventRecorder] Failed to persist #{@event_name}: #{e.class}: #{e.message}")
    nil
  end

  private

  def event_attributes
    model_name = @payload['model']
    prompt_tokens = integer_value(@payload['prompt_tokens'] || @payload['input_tokens'])
    completion_tokens = integer_value(@payload['completion_tokens'] || @payload['output_tokens'])
    total_tokens = integer_value(@payload['total_tokens']) || compact_sum(prompt_tokens, completion_tokens)

    {
      event_name: @event_name,
      feature: @payload['feature'],
      runtime_mode: @payload['runtime_mode'],
      status: @payload['status'],
      reason: @payload['reason'],
      provider: @payload['provider'].presence || provider_for(model_name),
      model: model_name,
      tool_name: @payload['tool_name'],
      schema_name: @payload['schema_name'],
      current_agent: @payload['current_agent'],
      channel_type: @payload['channel_type'],
      source: @payload['source'],
      request_id: @payload['request_id'],
      trace_id: @payload['trace_id'],
      session_id: @payload['session_id'],
      account_id: integer_value(@payload['account_id']),
      assistant_id: integer_value(@payload['assistant_id']),
      conversation_id: integer_value(@payload['conversation_id']),
      conversation_display_id: integer_value(@payload['conversation_display_id']),
      copilot_thread_id: integer_value(@payload['copilot_thread_id']),
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      total_tokens: total_tokens,
      duration_ms: duration_ms,
      credit_multiplier: Llm::Models.credit_multiplier_for(model_name),
      estimated_cost: estimated_cost(model_name, prompt_tokens:, completion_tokens:),
      blocked: blocked?,
      moderation_skipped: moderation_skipped?,
      schema_invalid: schema_invalid?,
      tool_failure: tool_failure?,
      error: error?,
      payload: summarized_payload
    }.compact
  end

  def summarized_payload
    @payload.except(*PROMOTED_PAYLOAD_KEYS.to_a).compact
  end

  def provider_for(model_name)
    return if model_name.blank?

    Llm::Config.provider_for_model(model_name)
  rescue StandardError
    nil
  end

  def estimated_cost(model_name, prompt_tokens:, completion_tokens:)
    return @payload['estimated_cost'].to_d if @payload['estimated_cost'].present?
    return if model_name.blank?
    return if prompt_tokens.nil? && completion_tokens.nil?

    Llm::Models.estimated_text_cost(
      model_name,
      input_tokens: prompt_tokens.to_i,
      output_tokens: completion_tokens.to_i
    )
  rescue StandardError
    nil
  end

  def duration_ms
    return unless @started_at && @finished_at

    ((@finished_at - @started_at) * 1000).round
  end

  def blocked?
    boolean_value(@payload['blocked']) || @event_name == 'llm.safety.blocked'
  end

  def moderation_skipped?
    boolean_value(@payload['moderation_skipped']) ||
      (@event_name == 'llm.moderation.unavailable' && @payload['failure_mode'].to_s == 'fail_open')
  end

  def schema_invalid?
    boolean_value(@payload['schema_invalid']) || @event_name == 'llm.schema.invalid'
  end

  def tool_failure?
    boolean_value(@payload['tool_failure']) ||
      (@event_name == 'llm.tool.complete' && boolean_value(@payload['error']))
  end

  def error?
    boolean_value(@payload['error']) || @event_name == 'llm.moderation.unavailable' || tool_failure?
  end

  def integer_value(value)
    return if value.blank?

    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end

  def boolean_value(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def compact_sum(*values)
    compact = values.compact
    return if compact.empty?

    compact.sum
  end
end
