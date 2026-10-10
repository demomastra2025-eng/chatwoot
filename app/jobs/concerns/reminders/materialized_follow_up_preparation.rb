module Reminders::MaterializedFollowUpPreparation
  private

  def prepare_captain_follow_up_dispatch(reminder, message_id, processing_claim, provider_check)
    records = captain_follow_up_records(reminder)
    unless records
      suppress_unpreparable_captain_follow_up!(reminder, message_id, processing_claim)
      return
    end

    conversation, assistant, anchor = records
    payload = { reminder: reminder, conversation: conversation, message_id: message_id,
                processing_claim: processing_claim, provider_check: provider_check,
                assistant: assistant, anchor: anchor }
    conversation.with_lock do
      conversation.reload
      conversation.with_captain_control_lock do
        conversation.reload
        reminder.with_lock do
          reminder.reload
          prepare_locked_captain_follow_up(payload)
        end
      end
    end
  end

  def prepare_locked_captain_follow_up(payload)
    reminder = payload[:reminder]
    return unless dispatchable?(reminder, payload[:message_id], payload[:processing_claim])

    message = Message.outgoing.find_by!(id: payload[:message_id], account_id: reminder.account_id)
    return unless message.additional_attributes.to_h['touch_id'].to_s == reminder.id.to_s

    unless captain_follow_up_current?(payload, message)
      suppress_stale_captain_follow_up!(reminder, message)
      return
    end
    return if provider_guard_stops?(*payload[:provider_check])

    message
  end

  def captain_follow_up_current?(payload, message)
    Captain::Conversation::FollowUpGuard.current?(
      reminder: payload[:reminder],
      conversation: payload[:conversation],
      assistant: payload[:assistant],
      anchor_message: payload[:anchor],
      message: message
    )
  end

  def suppress_unpreparable_captain_follow_up!(reminder, message_id, processing_claim)
    reason = 'Captain follow-up was canceled because a required record was removed before delivery'
    reminder.with_lock do
      reminder.reload
      next unless dispatchable?(reminder, message_id, processing_claim)
      next unless reminder.suppress_captain_follow_up_delivery!(message_id: message_id, reason: reason)

      fail_materialized_message_if_owned(reminder, message_id, reason)
    end
  end

  def fail_materialized_message_if_owned(reminder, message_id, reason)
    message = Message.outgoing.find_by(id: message_id, account_id: reminder.account_id)
    return unless message&.conversation_id == reminder.target_conversation_id
    return unless message.additional_attributes.to_h['touch_id'].to_s == reminder.id.to_s
    return if message.failed? || message.delivered? || message.read?

    message.update!(status: :failed, external_error: reason)
  end

  def captain_follow_up_records(reminder)
    metadata = reminder.metadata.to_h.deep_stringify_keys.fetch('captain_follow_up', {}).to_h
    conversation = Conversation.find_by(id: reminder.target_conversation_id, account_id: reminder.account_id)
    assistant = Captain::Assistant.find_by(id: metadata['assistant_id'], account_id: reminder.account_id)
    anchor = Message.find_by(id: metadata['anchor_message_id'], account_id: reminder.account_id)
    return unless conversation && assistant && anchor

    [conversation, assistant, anchor]
  end

  def suppress_stale_captain_follow_up!(reminder, message)
    reason = 'Captain follow-up was canceled because conversation control changed before delivery'
    reminder.suppress_captain_follow_up_delivery!(message_id: message.id, reason: reason)
    message.update!(status: :failed, external_error: reason) unless message.failed? || message.delivered? || message.read?
  end
end
