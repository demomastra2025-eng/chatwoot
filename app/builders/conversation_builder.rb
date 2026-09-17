class ConversationBuilder
  pattr_initialize [:params!, :contact_inbox!]

  def perform
    return create_new_conversation if @contact_inbox.inbox.email?

    Conversations::IdentityResolver.resolve_primary!(contact_inbox: @contact_inbox, attributes: conversation_params) do |conversation|
      sync_lead_form_submission(conversation)
    end
  end

  private

  def create_new_conversation
    conversation = ::Conversation.create!(conversation_params)
    sync_lead_form_submission(conversation)
    conversation
  end

  def sync_lead_form_submission(conversation)
    ::LeadForms::WidgetSubmissionSyncService.new(conversation: conversation, params: params).perform
  end

  def conversation_params
    additional_attributes = params[:additional_attributes]&.permit! || {}
    custom_attributes = params[:custom_attributes]&.permit! || {}
    status = params[:status].present? ? { status: params[:status] } : {}

    # TODO: temporary fallback for the old bot status in conversation, we will remove after couple of releases
    # commenting this out to see if there are any errors, if not we can remove this in subsequent releases
    # status = { status: 'pending' } if status[:status] == 'bot'
    {
      account_id: @contact_inbox.inbox.account_id,
      inbox_id: @contact_inbox.inbox_id,
      contact_id: @contact_inbox.contact_id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: additional_attributes,
      custom_attributes: custom_attributes,
      snoozed_until: params[:snoozed_until],
      assignee_id: params[:assignee_id],
      team_id: params[:team_id]
    }.merge(status)
  end
end
