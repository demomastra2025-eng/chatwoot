class Campaigns::OneoffConversationBuilder
  pattr_initialize [:campaign!, :contact!, :source_id, { campaign_run: nil, conversation_attributes: {} }]

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

  delegate :account, :inbox, :sender, :instructions, :template_params, :text_mode, to: :campaign, prefix: true

  def ensure_contact_inbox
    Outbound::ContactInboxResolver.new(
      inbox: campaign_inbox,
      contact: contact,
      source_id: source_id
    ).perform
  end

  def find_or_create_conversation
    existing_conversation = existing_campaign_conversation || reusable_single_conversation
    if existing_conversation.present?
      sync_conversation_attributes!(existing_conversation)
      return existing_conversation
    end

    conversation = ::Conversation.create!(conversation_params)
    conversation.update!(waiting_since: nil)
    conversation
  end

  def existing_campaign_message
    messages_scope = @conversation.messages.outgoing
                                  .where("additional_attributes ->> 'campaign_id' = ?", campaign.id.to_s)

    if campaign_run.present?
      messages_scope.find_by("additional_attributes ->> 'campaign_run_id' = ?", campaign_run.id.to_s)
    else
      messages_scope.first
    end
  end

  def build_campaign_message
    Messages::MessageBuilder.new(campaign_sender, @conversation, message_params).perform
  end

  def generated_campaign_content
    return @generated_campaign_content if defined?(@generated_campaign_content)

    @generated_campaign_content =
      if campaign_agent?
        Campaigns::CaptainGeneratedMessageService.new(
          campaign: campaign,
          conversation: @conversation
        ).perform[:content]
      else
        Outbound::RenderedTextService.new(
          content: campaign.message,
          conversation: @conversation,
          contact: contact,
          inbox: campaign_inbox,
          account: campaign_account,
          sender: campaign_sender
        ).render
      end
  end

  def message_params
    ActionController::Parameters.new({
                                       content: generated_campaign_content,
                                       campaign_id: campaign.id,
                                       campaign_run_id: campaign_run&.id,
                                       template_params: campaign_template_params
                                     })
  end

  def conversation_params
    {
      account_id: campaign.account_id,
      inbox_id: campaign_inbox.id,
      contact_id: contact.id,
      contact_inbox_id: @contact_inbox.id,
      campaign_id: conversation_campaign_id,
      status: :resolved,
      additional_attributes: merged_conversation_additional_attributes
    }
  end

  def sync_conversation_attributes!(conversation)
    updates = {}
    merged_attributes = merged_conversation_additional_attributes

    if merged_attributes.present?
      next_attributes = (conversation.additional_attributes || {}).merge(merged_attributes)
      updates[:additional_attributes] = next_attributes if next_attributes != conversation.additional_attributes
    end

    updates[:campaign_id] = nil if single_conversation_inbox? && conversation.campaign_id.present? && conversation.campaign_id != campaign.id

    conversation.update!(updates) if updates.present?
  end

  def merged_conversation_additional_attributes
    base_conversation_additional_attributes.merge(conversation_attributes.presence || {})
  end

  def base_conversation_additional_attributes
    return {} unless campaign_inbox.email?

    { mail_subject: campaign.title }
  end

  def existing_campaign_conversation
    @contact_inbox.conversations.find_by(campaign: campaign)
  end

  def reusable_single_conversation
    return unless single_conversation_inbox?

    @contact_inbox.conversations
                  .where(campaign_id: nil)
                  .order(created_at: :desc)
                  .first || @contact_inbox.conversations.order(created_at: :desc).first
  end

  def conversation_campaign_id
    return if single_conversation_inbox?

    campaign.id
  end

  def single_conversation_inbox?
    campaign_inbox.lock_to_single_conversation?
  end

  def campaign_agent?
    campaign_text_mode.to_s == 'agent'
  end
end
