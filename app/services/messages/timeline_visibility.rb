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

  class << self
    def apply(scope)
      non_activity = scope.where.not(message_type: :activity)
      useful_activity = scope.where(message_type: :activity)
                             .where('messages.source_id IS NULL OR messages.source_id !~ ?', NOISY_SOURCE_PATTERN)

      non_activity.or(useful_activity)
    end
  end
end
