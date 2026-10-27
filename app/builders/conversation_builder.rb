# started_by: a staff member who starts the conversation himself (the first message or call of a dialog, or a note on the empty
# screen of a person). Such a conversation is created silently: nothing is announced to the others as "a new conversation"
# (no realtime event, notification, automation rule, webhook, auto-assignment or "assigned" activity). The message that
# follows is delivered and announced as usual. The assignee is the owner of the person when he works in this inbox,
# otherwise the staff member. The flag skip_runtime_events is set on this record only (Current.suppress_runtime_events
# would also stop the delivery of the message) and a fresh instance is returned, so the flag does not leak into the later
# updates of the conversation, see Reminders::ConversationResolver. The conversation is open and in the hands of the staff
# member (no bot or AI takes it over, see Conversation#started_by_staff) and nobody waits for a reply yet. With #perform, when
# the inbox keeps one conversation per person and one exists, it is reused and nothing is created.
class ConversationBuilder
  pattr_initialize [:params!, :contact_inbox!, { started_by: nil }]

  def perform
    @contact_inbox.with_lock do
      look_up_exising_conversation || create_new_conversation
    end
  end

  # Always a new conversation, never an existing one: a call is a conversation of its own, see Voice::OutboundCallBuilder.
  def create_new
    @contact_inbox.with_lock { create_new_conversation }
  end

  private

  def look_up_exising_conversation
    return unless @contact_inbox.inbox.lock_to_single_conversation?

    @contact_inbox.conversations.last ||
      (@contact_inbox.contact_id.present? ? @contact_inbox.inbox.conversations.where(contact_id: @contact_inbox.contact_id).last : nil)
  end

  def create_new_conversation
    conversation = started_by.present? ? create_silently! : ::Conversation.create!(conversation_params)
    ::LeadForms::WidgetSubmissionSyncService.new(conversation: conversation, params: params).perform
    conversation
  end

  def create_silently!
    conversation = ::Conversation.new(conversation_params.merge(dialog_defaults))
    conversation.skip_runtime_events = true
    conversation.started_by_staff = true
    conversation.assignee = started_by if conversation.assignee_id.blank? && !conversation.contact_owner_assignable_to_conversation?
    conversation.save!
    ::Conversation.find(conversation.id)
  end

  # The team and the priority of the dialog the conversation joins are part of its first save, so nothing is reported as a change.
  def dialog_defaults
    params.slice(:team_id, :priority).permit(:team_id, :priority).to_h.symbolize_keys
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
      assignee_id: params[:assignee_id]
    }.merge(status)
  end
end
