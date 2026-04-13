class Campaigns::ConversationOneoffService < Campaigns::OneoffBaseService
  private

  def perform_delivery(contact:, delivery:, target_identifier:)
    message = Campaigns::OneoffConversationBuilder.new(
      campaign: campaign,
      contact: contact,
      campaign_run: current_campaign_run,
      source_id: target_identifier,
      conversation_attributes: conversation_attributes(contact: contact, target_identifier: target_identifier)
    ).perform

    delivery.mark_status!(status: :pending, metadata: { message_id: message.id })
  end

  def missing_target_error_message
    'Contact has no deliverable target for this inbox'
  end

  def conversation_attributes(contact:, target_identifier:)
    {}
  end
end
