class Conversations::ResolutionJob < ApplicationJob
  queue_as :low

  def perform(account:)
    # limiting the number of conversations to be resolved to avoid any performance issues
    resolvable_conversations = conversation_scope(account).limit(Limits::BULK_ACTIONS_LIMIT).to_a
    notified_ids = notified_conversation_ids(resolvable_conversations)
    resolvable_conversations.each do |conversation|
      # send message from bot that conversation has been resolved
      # do this is account.auto_resolve_message is set
      if account.auto_resolve_message.present? && notified_ids.include?(conversation.id)
        ::MessageTemplates::Template::AutoResolve.new(conversation: conversation).perform
      end
      conversation.add_labels(account.auto_resolve_label) if account.auto_resolve_label.present?
      conversation.toggle_status
    end
  end

  private

  # The scope only returns conversations whose contact is quiet in every channel (see
  # Conversation.without_recent_messages_in_other_conversations_of_contact). When several channels of one person are
  # closed in the same run the person gets a single "resolved" message, in the channel of the latest activity that can
  # still be written to; the other channels are closed silently.
  def notified_conversation_ids(conversations)
    conversations.group_by(&:contact_id).values.filter_map do |contact_conversations|
      notification_target(contact_conversations)&.id
    end
  end

  def notification_target(contact_conversations)
    return contact_conversations.first if contact_conversations.one?

    by_latest_activity = contact_conversations.sort_by { |conversation| [conversation.last_activity_at, conversation.id] }.reverse
    by_latest_activity.find(&:can_reply?) || by_latest_activity.first
  end

  def conversation_scope(account)
    base_scope = if account.auto_resolve_ignore_waiting
                   account.conversations.resolvable_not_waiting(account.auto_resolve_after)
                 else
                   account.conversations.resolvable_all(account.auto_resolve_after)
                 end
    # Exclude orphan conversations where contact was deleted but conversation cleanup is pending
    base_scope.where.not(contact_id: nil)
  end
end
