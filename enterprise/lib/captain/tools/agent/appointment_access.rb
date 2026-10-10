class Captain::Tools::Agent::AppointmentAccess
  APPOINTMENT_PURPOSE = 'captain.appointment_task'.freeze
  PATIENT_PURPOSE = 'captain.patient_selection'.freeze
  LIFETIME = 20.minutes

  def self.issue(assistant:, conversation:, appointment:)
    raise ArgumentError, 'Appointment account mismatch' unless appointment.account_id == assistant.account_id &&
                                                             conversation&.account_id == assistant.account_id

    verifier.generate(binding(assistant, conversation).merge(snapshot(appointment)),
                      purpose: APPOINTMENT_PURPOSE, expires_in: LIFETIME)
  end

  def self.resolve(token:, assistant:, conversation:, appointment_id:)
    return if token.blank? || conversation.blank? || conversation.account_id != assistant.account_id

    payload = verifier.verified(token, purpose: APPOINTMENT_PURPOSE)&.with_indifferent_access
    return unless payload && binding(assistant, conversation).all? { |key, value| payload[key] == value }
    return unless payload[:appointment_id].to_s == appointment_id.to_s

    appointment = assistant.account.scheduling_appointments.find_by(id: appointment_id)
    return unless appointment && snapshot(appointment).all? { |key, value| payload[key] == value }

    appointment
  end

  def self.issue_patient_selection(assistant:, contact:, patient_id:)
    raise ArgumentError, 'Patient account mismatch' unless contact&.account_id == assistant.account_id &&
                                                         assistant.account.contacts.exists?(id: patient_id)

    verifier.generate({ account_id: assistant.account_id, assistant_id: assistant.id,
                        contact_id: contact.id, patient_id: patient_id },
                      purpose: PATIENT_PURPOSE, expires_in: LIFETIME)
  end

  def self.valid_patient_selection?(token:, assistant:, contact:, patient_id:)
    return false unless contact&.account_id == assistant.account_id

    payload = verifier.verified(token, purpose: PATIENT_PURPOSE)&.with_indifferent_access
    payload.present? && payload[:account_id] == assistant.account_id && payload[:assistant_id] == assistant.id &&
      payload[:contact_id] == contact.id && payload[:patient_id].to_s == patient_id.to_s
  end

  def self.other_patient?(appointment, conversation)
    (appointment.patient_contact_id || appointment.contact_id) != conversation&.contact_id
  end

  def self.binding(assistant, conversation)
    { account_id: assistant.account_id, assistant_id: assistant.id,
      conversation_id: conversation.id, contact_id: conversation.contact_id }
  end
  private_class_method :binding

  def self.snapshot(appointment)
    { appointment_id: appointment.id, patient_id: appointment.patient_contact_id || appointment.contact_id,
      resource_id: appointment.resource_id, starts_at: appointment.starts_at&.utc&.iso8601(6),
      ends_at: appointment.ends_at&.utc&.iso8601(6), updated_at: appointment.updated_at&.utc&.iso8601(6) }
  end
  private_class_method :snapshot

  def self.verifier = Rails.application.message_verifier('captain.appointment_access')
  private_class_method :verifier
end
