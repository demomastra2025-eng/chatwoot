class Campaigns::OneoffConversationBuilder
  pattr_initialize [:campaign!, :contact!]

  attr_reader :contact_inbox, :conversation, :message

  def perform
    @contact_inbox = ensure_contact_inbox

    ActiveRecord::Base.transaction do
      @contact_inbox.lock!

      @conversation = find_or_create_conversation
      @message = existing_campaign_message || build_campaign_message
    end

    @message
  end

  private

  delegate :account, :inbox, :sender, :message, :template_params, to: :campaign, prefix: true

  def ensure_contact_inbox
    campaign_inbox.contact_inboxes.where(contact: contact).last || ContactInboxBuilder.new(contact: contact, inbox: campaign_inbox).perform
  end

  def find_or_create_conversation
    existing_conversation = @contact_inbox.conversations.find_by(campaign: campaign)
    return existing_conversation if existing_conversation.present?

    conversation = ::Conversation.create!(conversation_params)
    conversation.update!(waiting_since: nil)
    conversation
  end

  def existing_campaign_message
    @conversation.messages.outgoing
                 .where("additional_attributes ->> 'campaign_id' = ?", campaign.id.to_s)
                 .first
  end

  def build_campaign_message
    Messages::MessageBuilder.new(campaign_sender, @conversation, message_params).perform
  end

  def message_params
    ActionController::Parameters.new({
                                       content: campaign_message,
                                       campaign_id: campaign.id,
                                       template_params: campaign_template_params
                                     })
  end

  def conversation_params
    {
      account_id: campaign.account_id,
      inbox_id: campaign_inbox.id,
      contact_id: contact.id,
      contact_inbox_id: @contact_inbox.id,
      campaign_id: campaign.id,
      status: :resolved
    }
  end
end
