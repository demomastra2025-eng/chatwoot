# frozen_string_literal: true

class Messages::TimelineVisibility
  NOISY_ACTIVITY_ACTIONS = %w[
    ai_speaking
    business_faq_gate_fired
    business_faq_gate_result_injected
    caller_interrupted
    direct_tool_context_barrier_timeout
    direct_tool_speech_deferred
    direct_tool_speech_not_started
    faq_check_started
    faq_check_completed
    faq_result_ready
    faq_gate_released
    faq_gate_waiting
    incomplete_answer_model_stall
    ordinary_model_stall
    ordinary_answer_model_stall
    post_tool_model_stall
    incomplete_tool_call_wait
    terminal_confirmation_missing
    tool_started
    tool_progress
    tool_completed
    tool_failed
    tool_suppressed
    tool_async_completed
    tool_result_deferred
    tool_result_delivery_completed
    tool_result_delivery_failed
  ].freeze

  NOISY_SOURCE_PATTERN = ":(#{NOISY_ACTIVITY_ACTIONS.join('|')}):".freeze

  # Captain writes one activity line per executed tool
  # (Llm::Monitoring::ConversationTimelineProjector). The details belong to the
  # collapsed trace block of the AI reply and to the agent logs, so the rows
  # stay in the database but are not part of the staff timeline. They are
  # recognised by the projector's own markers (the source_id namespace or the
  # data type, whichever is present) and only among activity rows, never by the
  # localized text, so a message typed by a human is never hidden.
  # ActiveRecord::Store persists content_attributes as a JSON string, so the
  # data type is read from both the object and the string form of the column.
  CAPTAIN_TOOL_ACTIVITY_SQL = <<~SQL.squish.freeze
    messages.message_type = :captain_tool_activity_type
    AND (
      COALESCE(messages.source_id LIKE :captain_tool_source_pattern, FALSE)
      OR CASE json_typeof(messages.content_attributes)
         WHEN 'object' THEN COALESCE(messages.content_attributes -> 'data' ->> 'type', '') = :captain_tool_data_type
         WHEN 'string' THEN COALESCE(messages.content_attributes #>> '{}', '') ~ :captain_tool_data_type_pattern
         ELSE FALSE
         END
    )
  SQL

  class << self
    def apply(scope)
      non_activity = scope.where.not(message_type: :activity)
      useful_activity = scope.where(message_type: :activity)
                             .where('messages.source_id IS NULL OR messages.source_id !~ ?', NOISY_SOURCE_PATTERN)

      without_captain_tool_activity(non_activity.or(useful_activity))
    end

    def without_captain_tool_activity(scope)
      scope.where("NOT (#{CAPTAIN_TOOL_ACTIVITY_SQL})", captain_tool_activity_bindings)
    end

    def captain_tool_activity_bindings
      {
        captain_tool_activity_type: Message.message_types[:activity],
        captain_tool_source_pattern: "#{Llm::Monitoring::ConversationTimelineProjector::SOURCE_PREFIX}:%",
        captain_tool_data_type: Llm::Monitoring::ConversationTimelineProjector::TOOL_EVENT_TYPE,
        captain_tool_data_type_pattern: "\"type\"\\s*:\\s*\"#{Llm::Monitoring::ConversationTimelineProjector::TOOL_EVENT_TYPE}\""
      }
    end
  end
end
