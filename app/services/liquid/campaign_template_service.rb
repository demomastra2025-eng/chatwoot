class Liquid::CampaignTemplateService
  pattr_initialize [:campaign!, :contact!]

  def call(message)
    Outbound::RenderedTextService.new(
      content: message,
      conversation: latest_conversation_for_contact,
      contact: contact,
      inbox: campaign.inbox,
      account: campaign.account,
      sender: campaign.sender
    ).render
  end

  private

  def latest_conversation_for_contact
    campaign.inbox.conversations.where(contact: contact).order(last_activity_at: :desc).first
  end
end
