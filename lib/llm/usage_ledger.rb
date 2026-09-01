# frozen_string_literal: true

class Llm::UsageLedger
  CHAT_EVENT_NAME = 'llm.chat.complete'
  TRACKED_EVENT_NAMES = %w[
    llm.chat.complete
    llm.embedding.complete
    llm.moderation.complete
    llm.moderation.unavailable
    llm.rerank.complete
    llm.transcription.complete
  ].freeze

  class << self
    def record_event!(event)
      return if event.blank?
      return unless trackable_event?(event)
      return if event.payload.to_h.with_indifferent_access[:usage_counted] == false

      usage_event = LlmUsageEvent.find_or_initialize_by(llm_event_id: event.id)
      usage_event.assign_attributes(attributes_for(event))
      usage_event.save!
      usage_event
    end

    def summary(account: nil, range: nil, feature: nil, provider: nil)
      scoped = usage_scope(account: account, range: range, feature: feature, provider: provider)
      {
        request_count: scoped.count,
        estimated_cost: decimal_sum(scoped, :estimated_cost).to_f,
        total_tokens: integer_sum(scoped, :total_tokens),
        cached_tokens: integer_sum(scoped, :cached_tokens),
        reasoning_tokens: integer_sum(scoped, :reasoning_tokens),
        error_count: usage_error_count(scoped),
        by_feature: feature_breakdown(scoped)
      }
    end

    def spend(account: nil, range: nil, feature: nil, provider: nil)
      decimal_sum(usage_scope(account: account, range: range, feature: feature, provider: provider), :estimated_cost)
    end

    def usage_scope(account: nil, range: nil, feature: nil, provider: nil)
      LlmUsageEvent.all
                   .for_account(account_id(account))
                   .for_feature(feature)
                   .for_provider(provider)
                   .for_date_range(range)
    end

    private

    def trackable_event?(event)
      TRACKED_EVENT_NAMES.include?(event.event_name.to_s)
    end

    def attributes_for(event)
      payload = event.payload.to_h.with_indifferent_access
      generation = payload[:openrouter_generation].to_h.with_indifferent_access
      {
        account_id: event.account_id,
        occurred_at: event.created_at || Time.current,
        event_name: event.event_name,
        feature: event.feature,
        provider: event.provider,
        actual_provider: payload[:endpoint_provider].presence || generation[:provider_name],
        requested_model: payload[:requested_model].presence || payload[:model].presence || event.model,
        actual_model: generation[:model].presence || payload[:actual_model].presence || event.model,
        routing_profile: payload[:routing_profile].presence || payload[:runtime_profile].presence,
        status: event.status,
        error_code: event.error_code,
        prompt_tokens: event.prompt_tokens,
        completion_tokens: event.completion_tokens,
        reasoning_tokens: event.thinking_tokens,
        cached_tokens: integer_value(generation[:cached_tokens] || payload[:cached_tokens]),
        total_tokens: event.total_tokens,
        estimated_cost: decimal_value(generation[:cost] || payload[:cost] || event.estimated_cost),
        duration_ms: event.duration_ms,
        generation_id: payload[:openrouter_generation_id].presence || generation[:id],
        trace_id: event.trace_id,
        session_id: event.session_id,
        request_id: event.request_id,
        metadata: metadata_for(event, payload, generation)
      }.compact
    end

    def metadata_for(event, payload, generation)
      {
        llm_event_id: event.id,
        conversation_id: event.conversation_id,
        conversation_display_id: event.conversation_display_id,
        assistant_id: event.assistant_id,
        copilot_thread_id: event.copilot_thread_id,
        runtime_mode: event.runtime_mode,
        source: event.source,
        openrouter_generation: generation.presence,
        budget_decision: payload[:budget_decision]
      }.compact
    end

    def usage_error_count(scope)
      scope.where.not(error_code: [nil, '']).or(scope.where(status: %w[error failed blocked])).count
    end

    def feature_breakdown(scope)
      rows = scope.group(:feature).select(
        :feature,
        Arel.sql('COUNT(*) AS request_count'),
        Arel.sql('COALESCE(SUM(estimated_cost), 0) AS estimated_cost_sum'),
        Arel.sql('COALESCE(SUM(total_tokens), 0) AS total_tokens_sum'),
        Arel.sql('COALESCE(SUM(cached_tokens), 0) AS cached_tokens_sum'),
        Arel.sql('COALESCE(SUM(reasoning_tokens), 0) AS reasoning_tokens_sum')
      )

      rows.each_with_object({}) do |row, result|
        feature = row.feature
        result[feature || 'unknown'] = {
          request_count: integer_attr(row, 'request_count'),
          estimated_cost: decimal_attr(row, 'estimated_cost_sum').to_f,
          total_tokens: integer_attr(row, 'total_tokens_sum'),
          cached_tokens: integer_attr(row, 'cached_tokens_sum'),
          reasoning_tokens: integer_attr(row, 'reasoning_tokens_sum')
        }
      end
    end

    def integer_attr(row, name)
      row.read_attribute(name).to_i
    end

    def decimal_attr(row, name)
      value = row.read_attribute(name)
      value.respond_to?(:to_d) ? value.to_d : BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      BigDecimal(0)
    end

    def decimal_sum(scope, column)
      value = scope.sum(column)
      value.respond_to?(:to_d) ? value.to_d : BigDecimal(value.to_s)
    end

    def integer_sum(scope, column)
      scope.sum(column).to_i
    end

    def account_id(account)
      account.respond_to?(:id) ? account.id : account
    end

    def decimal_value(value)
      return if value.blank?

      value.to_d
    rescue ArgumentError, TypeError
      nil
    end

    def integer_value(value)
      return if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
