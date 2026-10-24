# frozen_string_literal: true

require 'securerandom'

# Records what a manager did with an AI suggestion (generated, applied, sent, dismissed ...) as an `llm.copilot.feedback` event, which
# lands in llm_events. The controller (the actions of the manager) and the reply suggestion job (generated) both use it.
#
# The text of the suggestion and the text that was finally sent are kept in full (keep_full_text: true), so that a later job can compare
# them. Without it the event carries a short preview of each, as before.
class Captain::CopilotFeedbackRecorder
  EVENT = 'copilot.feedback'
  PREVIEW_LIMIT = 1_000
  # Two texts of this size fit the payload budget of an llm event (8 KB) with room for the other keys, in Cyrillic too.
  FULL_TEXT_LIMIT = 1_500

  pattr_initialize [
    :account!, :user!, :conversation!, :requested_display_id!, :outcome!, :copilot_action!, :request_id!,
    { feature: nil, generated_text: nil, final_text: nil, keep_full_text: false, initial_suggestion_text: nil, edited_before_send: nil,
      follow_up_count: nil, message_id: nil, suggestion_request_id: nil, extra: {} }
  ]

  def self.record!(**)
    new(**).record!
  end

  def record!
    Llm::EventBus.publish(EVENT, payload)
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][CopilotFeedbackRecorder] Failed to record copilot feedback: #{e.class}: #{e.message}")
    nil
  end

  def payload
    context_attributes.merge(
      request_id: suggestion_request_id.presence || request_id.presence || SecureRandom.uuid,
      suggestion_request_id: suggestion_request_id.presence,
      edited_before_send: cast_boolean(edited_before_send),
      follow_up_count: cast_integer(follow_up_count),
      message_id: cast_integer(message_id)
    ).merge(text_attributes).merge(extra.to_h.symbolize_keys).compact
  end

  private

  def context_attributes
    action = copilot_action.to_s
    {
      feature: feature.presence || action, runtime_mode: 'captain_task', status: outcome, source: action.presence || 'copilot_ui',
      copilot_action: action, suggestion_outcome: outcome
    }.merge(actor_attributes, conversation_attributes)
  end

  def actor_attributes
    { account_id: account&.id, user_id: user&.id, user_name: user&.name }
  end

  def conversation_attributes
    {
      conversation_id: conversation&.id, conversation_display_id: conversation&.display_id || requested_display_id,
      channel_type: conversation&.inbox&.channel_type
    }
  end

  def text_attributes
    return { generated_reply_preview: preview(generated_text), final_reply_preview: preview(final_text) } unless keep_full_text

    suggestion, suggestion_cut = full_text(generated_text)
    final, final_cut = full_text(final_text)
    initial, initial_cut = full_text(initial_suggestion_text)
    {
      suggestion_text: suggestion, suggestion_text_truncated: (true if suggestion_cut),
      final_text: final, final_text_truncated: (true if final_cut),
      initial_suggestion_text: initial, initial_suggestion_text_truncated: (true if initial_cut)
    }
  end

  def preview(text)
    return if text.blank?

    Llm::Monitoring::PayloadSanitizer.call(text.to_s.strip.first(PREVIEW_LIMIT))
  end

  # [text, cut?]
  def full_text(text)
    stripped = text.to_s.strip
    return [nil, false] if stripped.blank?

    [stripped.first(FULL_TEXT_LIMIT), stripped.length > FULL_TEXT_LIMIT]
  end

  def cast_integer(value)
    value.present? ? value.to_i : nil
  end

  def cast_boolean(value)
    return if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end
end
