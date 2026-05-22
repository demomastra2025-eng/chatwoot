# frozen_string_literal: true

class Llm::Monitoring::MetricsSnapshot
  def initialize(scope: LlmEvent.all)
    @scope = scope.respond_to?(:except) ? scope.except(:order) : scope
  end

  def call
    chat_events = @scope.chat_completions
    embedding_events = @scope.where(event_name: 'llm.embedding.complete')
    transcription_events = @scope.where(event_name: 'llm.transcription.complete')
    moderation_events = @scope.where(event_name: %w[llm.moderation.complete llm.moderation.unavailable])
    blocked_events = @scope.blocked_events

    {
      total_events: @scope.count,
      request_count: chat_events.count,
      embedding_count: embedding_events.count,
      transcription_count: transcription_events.count,
      moderation_count: moderation_events.count,
      blocked_count: @scope.blocked_events.count,
      error_count: @scope.error_events.count,
      provider_failure_count: @scope.where(error_code: Llm::Monitoring::RuntimeHealth::PROVIDER_FAILURE_ERROR_CODES).count,
      moderation_skipped_count: @scope.moderation_skipped_events.count,
      schema_invalid_count: @scope.schema_invalid_events.count,
      tool_failure_count: @scope.tool_failure_events.count,
      total_tokens: chat_events.sum(:total_tokens),
      all_total_tokens: @scope.sum(:total_tokens),
      estimated_cost: chat_events.sum(:estimated_cost),
      total_estimated_cost: @scope.sum(:estimated_cost),
      avg_duration_ms: chat_events.average(:duration_ms)&.to_f,
      avg_queue_wait_ms: @scope.average(:queue_wait_ms)&.to_f,
      max_payload_bytes: @scope.maximum(:payload_bytes),
      payload_truncated_count: @scope.where(payload_truncated: true).count,
      retry_occurrences: @scope.sum(:retry_count),
      tool_call_occurrences: @scope.sum(:tool_calls_count),
      schema_invalid_occurrences: @scope.sum(:schema_invalid_count),
      by_feature: chat_events.group(:feature).count,
      by_model: chat_events.group(:model).count,
      by_provider: chat_events.group(:provider).count,
      cost_by_feature: @scope.group(:feature).sum(:estimated_cost),
      cost_by_model: @scope.group(:model).sum(:estimated_cost),
      cost_by_assistant_id: @scope.where.not(assistant_id: nil).group(:assistant_id).sum(:estimated_cost),
      moderation_by_status: moderation_events.group(:status).count,
      moderation_by_reason: compact_counts(moderation_events.group(:reason).count),
      moderation_by_stage: payload_value_counts(moderation_events, 'stage'),
      blocked_by_reason: compact_counts(blocked_events.group(:reason).count),
      blocked_by_stage: payload_value_counts(blocked_events, 'stage'),
      flagged_categories: payload_array_value_counts(moderation_events.where(status: 'flagged'), 'flagged_categories'),
      by_event_feature: @scope.group(:event_name, :feature).count,
      by_event_name: @scope.group(:event_name).count,
      by_status: @scope.group(:status).count,
      last_event_at: @scope.maximum(:created_at)
    }
  end

  private

  def compact_counts(counts)
    counts.each_with_object({}) do |(key, value), result|
      next if key.blank?

      result[key] = value
    end
  end

  def payload_value_counts(scope, key)
    scope.pluck(Arel.sql("payload ->> '#{key}'")).each_with_object(Hash.new(0)) do |value, counts|
      next if value.blank?

      counts[value] += 1
    end
  end

  def payload_array_value_counts(scope, key)
    scope.pluck(:payload).each_with_object(Hash.new(0)) do |payload, counts|
      Array(payload[key] || payload[key.to_s]).each do |value|
        next if value.blank?

        counts[value.to_s] += 1
      end
    end
  end
end
