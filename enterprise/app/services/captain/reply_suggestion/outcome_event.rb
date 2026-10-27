# frozen_string_literal: true

# The llm_events row of a reply suggestion request: `captain.reply_suggestion.complete`, one per request (status = outcome).
# It is published with the block form of Llm::EventBus.publish around the run, so duration_ms is the real run duration; the
# rows of the run (llm.chat.*, llm.tool.*, llm.run.complete, llm.copilot.feedback) share its request_id.
module Captain::ReplySuggestion::OutcomeEvent
  EVENT = 'captain.reply_suggestion.complete'
  FEATURE = 'reply_suggestion'
  REASON_PREVIEW_LIMIT = 300
  # The counters of the run that the event carries: the tool calls, the model steps (and how many asked for several tools), what was
  # read at the start instead of with tools. total_ms (the whole request) is set in #fill!.
  STAT_KEYS = %w[tools_called turns handoffs_count steps tool_steps parallel_steps max_tools_in_step preloaded preload_ms].freeze

  class << self
    # What is known before the run starts.
    def base_payload(state, conversation: nil)
      {
        feature: FEATURE, source: FEATURE, runtime_mode: state['engine'] == 'agent' ? 'captain_runtime' : 'captain_task',
        request_id: state['id'], account_id: state['account_id'], user_id: state['user_id'], assistant_id: state['assistant_id'],
        conversation_id: state['conversation_id'], conversation_display_id: conversation&.display_id || state['conversation_display_id'],
        channel_type: conversation&.inbox&.channel_type, engine: state['engine'], budget_ms: state['budget_seconds'].to_i * 1000,
        queue_wait_ms: queue_wait_ms(state)
      }.compact
    end

    # Fills the payload of the event inside the block of the publish: it is recorded when the block ends.
    def fill!(event, state, outcome, stats: {})
      status = outcome[:outcome].to_s
      event.merge!(
        'status' => status, 'outcome' => status, 'error' => status == 'failed', 'reason' => reason_for(outcome),
        'error_code' => (outcome[:reason_code].to_s.presence if status == 'failed'), 'reason_preview' => reason_preview(outcome),
        'current_agent' => outcome.dig(:agent, 'name'), 'stage' => outcome[:stage], 'detail' => outcome[:detail],
        'error_class' => outcome[:error_class], 'total_ms' => total_ms(state), 'stale' => stale?(state)
      )
      event.merge!(stats.to_h.stringify_keys.slice(*STAT_KEYS))
      event.compact!
      event
    end

    # The event of a request that never ran (cancelled in the queue, lost in the queue) or whose run was killed.
    def publish_finished(state, outcome, conversation: nil, stats: {})
      Llm::EventBus.publish(EVENT, base_payload(state, conversation: conversation)) { |event| fill!(event, state, outcome, stats: stats) }
    end

    # A precondition rejected the request: no job, no state.
    def publish_unavailable(account:, user:, conversation:, error_code:)
      Llm::EventBus.publish(
        EVENT,
        {
          feature: FEATURE, source: FEATURE, status: 'unavailable', outcome: 'unavailable', error: false, reason: error_code.to_s,
          account_id: account&.id, user_id: user&.id, conversation_id: conversation&.id, conversation_display_id: conversation&.display_id,
          channel_type: conversation&.inbox&.channel_type
        }.compact
      )
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ReplySuggestion] unavailable event skipped: #{e.class}: #{e.message}")
      nil
    end

    private

    def reason_for(outcome)
      case outcome[:outcome].to_s
      when 'failed' then outcome[:reason_code].to_s
      when 'no_reply', 'human_needed' then outcome[:reason_source].to_s
      when 'cancelled' then 'user'
      end
    end

    def reason_preview(outcome)
      outcome[:reason].to_s.first(REASON_PREVIEW_LIMIT).presence
    end

    def queue_wait_ms(state)
      started = state['started_at'].presence || Time.current.utc.iso8601(3)
      [((Time.zone.parse(started) - Time.zone.parse(state['created_at'])) * 1000).round, 0].max
    end

    def total_ms(state)
      [((Time.current - Time.zone.parse(state['created_at'])) * 1000).round, 0].max
    end

    def stale?(state)
      Captain::ReplySuggestion::StatePresenter.stale?(state)
    rescue StandardError
      nil
    end
  end
end
