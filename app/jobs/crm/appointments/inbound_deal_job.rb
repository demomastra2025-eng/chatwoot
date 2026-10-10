class Crm::Appointments::InboundDealJob < ApplicationJob
  queue_as :low

  def perform(account_id, message_id)
    message = Message.find_by(account_id: account_id, id: message_id)
    return unless message&.incoming? && !message.private?

    conversation = message.conversation
    return unless conversation.account_id == account_id && conversation.contact_inbox.present?

    Crm::Deals::AutoCreateFromChannelContactService.new(
      contact_inbox: conversation.contact_inbox, conversation: conversation, message: message
    ).perform
  end
end
