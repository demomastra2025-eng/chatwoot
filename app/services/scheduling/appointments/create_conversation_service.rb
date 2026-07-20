class Scheduling::Appointments::CreateConversationService
  def initialize(account:, appointment:, inbox:, params:, actor:)
    @account = account
    @appointment = appointment
    @inbox = inbox
    @params = params.to_h.deep_symbolize_keys
    @actor = actor
  end

  def perform
    contact = account.contacts.find(params[:contact_id])

    appointment.with_lock do
      ensure_current_context!(contact)
      if existing_conversation_matches?(contact)
        appointment.reload
      else
        create_and_link_conversation!(contact)
      end
    end
  end

  private

  attr_reader :account, :actor, :appointment, :inbox, :params

  def ensure_current_context!(contact)
    return if appointment.contact_id == contact.id

    raise Scheduling::Error.new(
      code: 'APPOINTMENT_CONTEXT_CHANGED',
      message: 'Appointment contact changed before conversation creation',
      status: :conflict
    )
  end

  def existing_conversation_matches?(contact)
    conversation = appointment.conversation
    return false if conversation.blank?
    return false unless conversation.contact_id == contact.id && conversation.inbox_id == inbox.id
    return false if params[:contact_inbox_id].present? && conversation.contact_inbox_id != params[:contact_inbox_id].to_i
    return false if params[:source_id].present? && conversation.contact_inbox.source_id != params[:source_id]

    true
  end

  def ensure_conversation_absent!
    return if appointment.conversation_id.blank?

    raise Scheduling::Error.new(
      code: 'APPOINTMENT_CONVERSATION_CHANGED',
      message: 'Appointment conversation changed before conversation creation',
      status: :conflict
    )
  end

  def create_and_link_conversation!(contact)
    ensure_conversation_absent!
    contact_inbox = resolve_contact_inbox(contact)
    conversation = ConversationBuilder.new(
      params: { assignee_id: actor&.id },
      contact_inbox: contact_inbox
    ).perform
    raise ActiveRecord::RecordInvalid, conversation unless conversation.persisted?

    Scheduling::Appointments::UpsertService.new(
      account: account,
      params: {
        contact_id: contact.id,
        conversation_id: conversation.id
      },
      appointment: appointment,
      actor: actor
    ).perform
  end

  def resolve_contact_inbox(contact)
    return scoped_contact_inboxes(contact).find(params[:contact_inbox_id]) if params[:contact_inbox_id].present?

    ContactInboxBuilder.new(
      contact: contact,
      inbox: inbox,
      source_id: params[:source_id]
    ).perform
  end

  def scoped_contact_inboxes(contact)
    ContactInbox.joins(:inbox).where(
      contact_id: contact.id,
      inbox_id: inbox.id,
      inboxes: { account_id: account.id }
    )
  end
end
