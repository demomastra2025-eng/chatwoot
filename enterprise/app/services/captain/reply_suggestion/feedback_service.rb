# frozen_string_literal: true

# What the manager did with a reply suggestion, recorded as an `llm.copilot.feedback` event (so in llm_events), together with what a
# later job needs to learn from it:
#
#   applied           the draft was inserted into the reply box
#   sent              the message was sent: the sent text and the text of the suggestion, in full, to compare them
#   dismissed         the draft was rejected: the text of the suggestion; the next message of the manager follows on the event
#                     (see DismissalTracker)
#   notice_dismissed  the manager closed the "no reply needed" / "staff must answer" / "failed" notice
#
# `generated` is recorded by the job that made the suggestion.
class Captain::ReplySuggestion::FeedbackService
  class NotFoundError < StandardError; end

  # The manager acted on the suggestion: it never reappears on return.
  CONSUMING_OUTCOMES = %w[applied dismissed notice_dismissed].freeze
  FULL_TEXT_OUTCOMES = %w[sent dismissed].freeze

  pattr_initialize [
    :account!, :user!, :conversation, :outcome!, :copilot_action!, :requested_display_id,
    { request_id: nil, suggestion_request_id: nil, generated_text: nil, final_text: nil, edited_before_send: nil, follow_up_count: nil,
      message_id: nil }
  ]

  # The manager used the draft: its agent leads the dialog of the next suggestions (see StickyAgent), and its approval cards stay
  # until the manager acts on them (a later suggestion does not discard them, see ActionApprovalService.discard_superseded!).
  USED_OUTCOMES = %w[applied sent].freeze

  def perform
    record = load_record!
    record_event(record)
    return unless record

    Captain::ReplySuggestion::RequestStore.consume!(record['id']) if CONSUMING_OUTCOMES.include?(outcome)
    rejected(record) if outcome == 'dismissed'
    used(record) if USED_OUTCOMES.include?(outcome)
  end

  private

  # A rejected suggestion leaves no approval card and no sticky agent of its own behind.
  def rejected(record)
    remember_dismissal(record)
    Captain::ReplySuggestion::ActionApprovalService.discard_for_request!(
      account_id: account.id, conversation_id: record['conversation_id'], request_id: record['id'], reason: 'suggestion_dismissed'
    )
    Captain::ReplySuggestion::StickyAgent.withdraw!(conversation, request_id: record['id'])
  end

  def used(record)
    return unless record['status'] == 'draft'

    Captain::ReplySuggestion::ActionApprovalService.keep_for_request!(
      account_id: account.id, conversation_id: record['conversation_id'], request_id: record['id']
    )
    Captain::ReplySuggestion::StickyAgent.confirm!(
      conversation, Captain::ReplySuggestion::StickyAgent.agent_id_of_result(record['result']), request_id: record['id']
    )
  end

  # The request of the suggestion must be this user's, in this account and conversation.
  def load_record!
    return if suggestion_request_id.blank?

    record = Captain::ReplySuggestion::RequestStore.fetch_raw(suggestion_request_id)
    # The state lives 30 minutes; a manager who edits the draft for longer still has the text they sent recorded.
    return if record.nil? && outcome == 'sent'
    raise NotFoundError unless owned?(record)

    record
  end

  def owned?(record)
    return false unless record && record['account_id'] == account.id && record['user_id'] == user.id

    conversation.nil? || record['conversation_id'] == conversation.id
  end

  def record_event(record)
    Captain::CopilotFeedbackRecorder.record!(
      account: account, user: user, conversation: conversation, requested_display_id: requested_display_id, outcome: outcome,
      copilot_action: copilot_action, request_id: request_id, suggestion_request_id: suggestion_request_id,
      generated_text: suggestion_text(record), final_text: sent_text, keep_full_text: FULL_TEXT_OUTCOMES.include?(outcome),
      initial_suggestion_text: initial_suggestion_text(record), edited_before_send: edited_before_send, follow_up_count: follow_up_count,
      message_id: message_id, extra: event_extras(record)
    )
  end

  def event_extras(record)
    return {} unless record

    { engine: record['engine'], based_on_message_id: record['based_on_message_id'],
      reason_preview: (record.dig('result', 'reason').to_s.first(300).presence if outcome == 'notice_dismissed') }.compact
  end

  # The text the AI proposed and the manager worked with: what was inserted (it may be a follow-up of the first draft), else the draft.
  def suggestion_text(record)
    generated_text.presence || draft_message(record)
  end

  # The first draft, when the text worked with is a refinement of it.
  def initial_suggestion_text(record)
    first = draft_message(record)
    first if first.present? && generated_text.present? && first.strip != generated_text.to_s.strip
  end

  def draft_message(record)
    return unless record && record['status'] == 'draft'

    record.dig('result', 'message').presence
  end

  # The text that was sent: the message itself when the manager's own message can be found, else what the client reported.
  def sent_text
    return final_text unless outcome == 'sent'

    sent_message&.content.presence || final_text
  end

  def sent_message
    return if message_id.blank? || conversation.blank?

    Message.where(conversation_id: conversation.id, message_type: :outgoing, private: false, sender_type: 'User', sender_id: user.id)
           .find_by(id: message_id)
  end

  def remember_dismissal(record)
    return if conversation.blank?

    Captain::ReplySuggestion::DismissalTracker.arm!(
      account_id: account.id, user_id: user.id, conversation_id: conversation.id, suggestion_request_id: record['id']
    )
  end
end
