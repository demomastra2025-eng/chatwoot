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
    linked_appointment_if_present(contact) || create_conversation_with_locks(contact)
  end

  private

  attr_reader :account, :actor, :appointment, :inbox, :params

  def linked_appointment_if_present(contact)
    return if appointment.conversation_id.blank?

    appointment.with_lock do
      ensure_current_context!(contact)
      return appointment.reload if existing_conversation_matches?(contact)

      ensure_conversation_absent!
    end
    nil
  end

  def create_conversation_with_locks(contact)
    result = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      # ConversationBuilder's after_create resolver claims this advisory lock.
      # Take it before Contact (and the appointment) to match Thread routing.
      Conversations::CommunicationThreadResolver.lock_contact_thread!(account.id, contact.id)
      # Merge and conversation owner-sync both acquire Contact before ContactInbox.
      # Keep this row locked through the appointment event and identity resolution.
      result, reused = contact.with_lock do
        contact_inbox = resolve_contact_inbox(contact)
        contact_inbox.lock!
        link_or_reuse(contact, contact_inbox)
      end
      # A competing request may link while we wait. Discard the unused ContactInbox on a retry.
      raise ActiveRecord::Rollback if reused
    end
    result
  end

  def link_or_reuse(contact, contact_inbox)
    appointment.with_lock do
      ensure_current_context!(contact)
      return [appointment.reload, true] if existing_conversation_matches?(contact)

      result = create_and_link_conversation!(contact_inbox)
      [result, false]
    end
  end

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

  def create_and_link_conversation!(contact_inbox)
    ensure_conversation_absent!
    conversation = ConversationBuilder.new(
      params: { assignee_id: actor&.id },
      contact_inbox: contact_inbox
    ).perform
    raise ActiveRecord::RecordInvalid, conversation unless conversation.persisted?

    # Contact.owner is the relationship owner; the appointment only links the
    # conversation and keeps its historical owner_id column dormant.
    appointment.update!(conversation: conversation)
    appointment
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
