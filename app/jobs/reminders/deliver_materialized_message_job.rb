class Reminders::DeliverMaterializedMessageJob < ApplicationJob
  queue_as :outbound_messages

  discard_on ActiveRecord::RecordNotFound

  def perform(reminder_id, message_id, processing_claim)
    reminder = Reminder.find(reminder_id)
    reminder.with_lock do
      reminder.reload
      next unless reminder.processing? || reminder.completed?
      next unless reminder.processing_claim_token == processing_claim
      next unless materialized_message_id(reminder) == message_id.to_s
      next if reminder.delivery_dispatched_for?(message_id)

      message = Message.outgoing.find_by!(id: message_id, account_id: reminder.account_id)
      next unless message.additional_attributes.to_h['touch_id'].to_s == reminder.id.to_s

      SendReplyJob.perform_now(message.id)
      reminder.mark_delivery_dispatched!(message.id)
    end
  end

  private

  def materialized_message_id(reminder)
    reminder.metadata.to_h[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY].to_s
  end
end
