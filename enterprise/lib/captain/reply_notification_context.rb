class Captain::ReplyNotificationContext
  def self.for(account:, conversation:, incoming_message_id:, assistant:)
    new(account: account, conversation: conversation, incoming_message_id: incoming_message_id, assistant: assistant).perform
  end

  def initialize(account:, conversation:, incoming_message_id:, assistant:)
    @account = account
    @conversation = conversation
    @incoming_message_id = incoming_message_id
    @assistant = assistant
  end

  def perform
    return unless eligible?

    incoming = @conversation.messages.incoming.find_by(id: @incoming_message_id, account_id: @account.id)
    return unless current_contact_message?(incoming)

    delivery = linked_delivery(incoming)
    return unless current_delivery?(delivery)

    reminder = reminder_for(delivery)
    confirmation = confirmation_for(delivery)
    return unless reminder.present? || confirmation.present?
    return unless reminder_for_current_contact?(reminder)

    payload(reminder, confirmation, delivery)
  end

  private

  def eligible?
    @incoming_message_id.present? && @conversation.contact_id.present? && @conversation.account_id == @account.id
  end

  def current_contact_message?(message)
    message&.sender_type == 'Contact' && message.sender_id == @conversation.contact_id
  end

  def current_delivery?(message)
    message&.outgoing? && message.account_id == @account.id && message.conversation_id == @conversation.id
  end

  def reminder_for_current_contact?(reminder)
    reminder.blank? || reminder.target_contact_id.blank? || reminder.target_contact_id == @conversation.contact_id
  end

  def resolved_confirmation(incoming)
    ConfirmationRequest.find_by(
      account_id: @account.id, conversation_id: @conversation.id, contact_id: @conversation.contact_id,
      resolved_message_id: incoming.id
    )
  end

  def linked_delivery(incoming)
    replied_delivery(incoming) || resolved_confirmation(incoming)&.delivery_message
  end

  def replied_delivery(incoming)
    reference = incoming.content_attributes.to_h.with_indifferent_access
    scope = @conversation.messages.outgoing.where(account_id: @account.id)
    return scope.find_by(id: reference[:in_reply_to]) if reference[:in_reply_to].present?
    return scope.find_by(source_id: reference[:in_reply_to_external_id]) if reference[:in_reply_to_external_id].present?
  end

  def reminder_for(delivery)
    id = delivery.additional_attributes.to_h['touch_id'] || delivery.content_attributes.to_h['touch_id']
    @account.reminders.find_by(id: id) if id.present?
  end

  def confirmation_for(delivery)
    ConfirmationRequest.find_by(
      account_id: @account.id, conversation_id: @conversation.id, contact_id: @conversation.contact_id,
      delivery_message_id: delivery.id
    )
  end

  def payload(reminder, confirmation, delivery)
    appointment = scoped_appointment(reminder, confirmation)
    {
      kind: reminder.present? ? 'reminder' : 'notification',
      reminder_id: reminder&.id,
      confirmation_request_id: confirmation&.id,
      appointment_id: appointment&.id,
      appointment: appointment && Captain::AppointmentContext.new(account: @account, conversation: @conversation).card(appointment),
      delivery_message_id: delivery.id
    }.compact
  end

  def scoped_appointment(reminder, confirmation)
    id = if reminder&.remindable_type == 'Scheduling::Appointment'
           reminder.remindable_id
         elsif confirmation&.subject_type == 'Scheduling::Appointment'
           confirmation.subject_id
         end
    return if id.blank?

    scope = Captain::Tools::Agent::PatientScope.new(assistant: @assistant, conversation: @conversation)
    scope.appointments.includes(:resource, :service).find_by(id: id)
  end
end
