# frozen_string_literal: true

class Captain::Conversation::FollowUpChainService
  def self.cancel_for!(conversation, reason:)
    return 0 unless conversation.present? && conversation.account_id.present?

    conversation_ids = Captain::Conversation::ControlService.messages_scope(conversation).select(:conversation_id)
    reminders = conversation.account.reminders.captain_follow_up.open_statuses.where(
      'conversation_id IN (:conversation_ids) OR target_conversation_id IN (:conversation_ids)',
      conversation_ids: conversation_ids
    )
    cancelled = 0
    reminders.find_each do |reminder|
      next if reminder.delivery_materialized?

      reminder.cancel!(reason)
      cancelled += 1 if reminder.cancelled?
    end
    cancelled
  end
end

Captain::Conversation::FollowUpChainService.prepend_mod_with('Captain::Conversation::FollowUpChainService')
