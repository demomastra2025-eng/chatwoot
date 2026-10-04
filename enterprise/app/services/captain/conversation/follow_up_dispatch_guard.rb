# frozen_string_literal: true

class Captain::Conversation::FollowUpDispatchGuard
  def self.with_provider_boundary(message)
    attributes = message.additional_attributes.to_h.deep_stringify_keys
    return yield unless attributes['captain_follow_up'].is_a?(Hash)

    reminder = Reminder.find_by(
      id: attributes['touch_id'],
      account_id: message.account_id,
      action_type: Reminder.action_types.fetch('captain_follow_up')
    )
    return fail_orphaned_message!(message) unless reminder

    new(message, reminder).with_provider_boundary { yield }
  end

  def self.allow?(message)
    with_provider_boundary(message) { true }
  end

  def self.fail_orphaned_message!(message)
    reason = 'Captain follow-up was canceled because its reminder could not be found'
    message.update!(status: :failed, external_error: reason) unless message.failed? || message.delivered? || message.read?
    false
  end

  def initialize(message, reminder)
    @message = message
    @reminder = reminder
  end

  def with_provider_boundary
    records = follow_up_records
    return suppress_stale_delivery! unless records

    conversation, account, assistant, anchor = records
    result = false
    with_follow_up_locks(conversation, account, assistant) do
      reload_control_records(conversation, account, assistant, anchor)
      if Captain::Conversation::FollowUpGuard.current?(
        reminder: reminder,
        conversation: conversation,
        assistant: assistant,
        anchor_message: anchor,
        message: message
      )
        if dispatch_attempt_authorized?
          result = yield
        end
      else
        suppress_stale_delivery!
      end
    end
    result
  rescue ActiveRecord::RecordNotFound
    suppress_stale_delivery!
  end

  private

  attr_reader :message, :reminder

  def follow_up_records
    metadata = reminder.metadata.to_h.deep_stringify_keys.fetch('captain_follow_up', {}).to_h
    conversation = Conversation.find_by(id: reminder.target_conversation_id, account_id: reminder.account_id)
    account = Account.find_by(id: reminder.account_id)
    assistant = Captain::Assistant.find_by(id: metadata['assistant_id'], account_id: reminder.account_id)
    anchor = Message.find_by(id: metadata['anchor_message_id'], account_id: reminder.account_id)
    return unless conversation && account && assistant && anchor
    return unless account.id == conversation.account_id && assistant.account_id == conversation.account_id

    [conversation, account, assistant, anchor]
  end

  # Keep the provider invocation inside the shared writer lock order:
  # conversation, control owner, inbox assignment, account, assistant, reminder.
  # This fences takeover, inbox reassignment, feature changes, and config edits
  # until the provider has accepted or scheduled a retry.
  def with_follow_up_locks(conversation, account, assistant)
    conversation.with_lock do
      conversation.reload
      conversation.with_captain_control_lock do
        Telephony::AiVoice::AssistantAssignmentLock.acquire!(conversation.inbox_id)
        account.with_lock do
          account.reload
          assistant.with_lock do
            assistant.reload
            reminder.with_lock { yield }
          end
        end
      end
    end
  end

  def reload_control_records(conversation, account, assistant, anchor)
    conversation.reload
    account.reload
    assistant.reload
    anchor.reload
    reminder.reload
    message.reload
  end

  def dispatch_attempt_authorized?
    return false if reminder.captain_follow_up_delivery_suppressed?

    if reminder.delivery_dispatched_for?(message.id)
      return reminder.delivery_dispatch_started_for?(message.id) && reminder.delivery_stage == 'retry_scheduled'
    end

    return false if reminder.delivery_dispatch_started_for?(message.id)

    reminder.mark_delivery_dispatch_started!(message.id)
  end

  def suppress_stale_delivery!
    reason = 'Captain follow-up was canceled because conversation control changed before delivery'
    reminder.with_lock do
      reminder.reload
      reminder.suppress_captain_follow_up_delivery!(message_id: message.id, reason: reason)
    end
    message.update!(status: :failed, external_error: reason) unless message.failed? || message.delivered? || message.read?
    false
  end
end
