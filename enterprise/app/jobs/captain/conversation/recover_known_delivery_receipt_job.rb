class Captain::Conversation::RecoverKnownDeliveryReceiptJob < ApplicationJob
  queue_as :captain_outbound_messages_v2

  def perform(message_id, reminder_id, claim_token)
    message = Message.outgoing.find_by(id: message_id, sender_type: 'Captain::Assistant')
    return unless message && known_receipt?(message)

    # Fence reconciliation first, so the reminder marker reflects the actual
    # durable outcome rather than the state before a pending ACK was applied.
    SendReplyJob.perform_now(message.id)
    Reminders::DeliverMaterializedMessageJob.new.finalize_recovered_delivery(reminder_id, message.id, claim_token)
  end

  private

  def known_receipt?(message)
    state = message.additional_attributes.to_h['captain_delivery_state']
    return true if %w[submitted provider_failed].include?(state)
    return false unless message.inbox.channel_type == 'Channel::Tiktok' && message.source_id.present?

    %w[dispatching outcome_unknown].include?(state)
  end
end
