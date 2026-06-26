module Enterprise::Message
  private

  def mark_pending_conversation_as_open_for_human_response
    return unless captain_auto_open_candidate?

    without_current_actor do
      Conversations::StatusTransitionService.new(
        conversation: conversation,
        params: { status: 'open' },
        source: 'system'
      ).perform
      return unless conversation.saved_change_to_status?

      turn_off_captain_typing_indicator
      create_captain_auto_open_activity_message
    end
  end

  def captain_auto_open_candidate?
    captain_pending_conversation? &&
      human_response? &&
      !private? &&
      !scheduled_touch_message? &&
      !template_bootstrap_message?
  end

  def captain_pending_conversation?
    return false unless conversation.pending?

    ::CaptainInbox.exists?(inbox_id: conversation.inbox_id)
  end

  def template_bootstrap_message?
    additional_attributes['template_params'].present? &&
      !conversation.messages.incoming.exists?
  end

  def create_captain_auto_open_activity_message
    ::Conversations::ActivityMessageJob.perform_later(
      conversation,
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content: I18n.t('conversations.activity.captain.auto_opened_after_agent_reply')
    )
  end

  def turn_off_captain_typing_indicator
    captain_assistant = ::CaptainInbox.find_by(inbox_id: conversation.inbox_id)&.captain_assistant
    Captain::Conversation::TypingIndicatorService.turn_off(
      conversation: conversation,
      assistant: captain_assistant
    )
  end

  def without_current_actor
    previous_user = Current.user
    previous_executed_by = Current.executed_by
    Current.user = nil
    Current.executed_by = nil

    yield
  ensure
    Current.user = previous_user
    Current.executed_by = previous_executed_by
  end
end
