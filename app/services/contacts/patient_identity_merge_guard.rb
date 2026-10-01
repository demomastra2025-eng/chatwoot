class Contacts::PatientIdentityMergeGuard
  # Channel merges by phone (WhatsApp Web, Telegram Personal). M7 hard invariant: an automatic merge never absorbs a
  # chat contact into a patient card or a patient card into a chat contact, whatever identity either side carries.
  # "Patient card" is durable and identity based (Contacts::SharedPhone.card?): card flag, MedElement code, a valid
  # IIN, or any appointment where the contact is the patient. A phone cannot tell a family member from the person.
  def self.allowed?(source_contact:, target_contact:)
    return false if source_contact.account_id != target_contact.account_id
    return false if Contacts::SharedPhone.card?(source_contact) || Contacts::SharedPhone.card?(target_contact)
    return false if patient_binding_write_in_flight?(source_contact, target_contact)

    !conflicting_identities?(identity(source_contact), identity(target_contact))
  end

  # Operator merges (dashboard, MedElement conflicts, Copilot, identify) never absorb a separate patient card
  # into another contact or a contact into it, unless both sides carry the same confirmed provider identity.
  def self.explicit_merge_allowed?(base_contact:, mergee_contact:)
    return false if base_contact.account_id != mergee_contact.account_id

    base = identity(base_contact)
    mergee = identity(mergee_contact)
    return false if conflicting_identities?(mergee, base)
    return true if matching_identity?(mergee, base)

    !patient_card?(base_contact, base) && !patient_card?(mergee_contact, mergee)
  end

  # A merge re-points appointment.patient_contact_id outside the upsert write fence (ensure_write_target_unchanged!).
  # While a provider write for such an appointment is started or awaits verification, its captured binding must stay.
  def self.patient_binding_write_in_flight?(*contacts)
    contact_ids = contacts.filter_map { |contact| contact&.id }
    return false if contact_ids.empty?

    appointments = Scheduling::Appointment.where(patient_contact_id: contact_ids).select(:id)
    Integrations::Medelement::AppointmentPatientBindingSnapshot.writes_in_flight(appointments).exists?
  end

  # Call inside the merge transaction, before the in-flight check. The executor publishes its write phase while it
  # holds the appointment row lock (Executor#with_patient_identity_write_fence), so locking the bound appointments
  # first makes the check and the patient_contact_id re-point atomic with respect to a starting provider write.
  def self.lock_patient_bindings!(*contacts)
    contact_ids = contacts.filter_map { |contact| contact&.id }
    return [] if contact_ids.empty?

    Scheduling::Appointment.where(patient_contact_id: contact_ids).or(Scheduling::Appointment.where(contact_id: contact_ids))
                           .order(:id).lock.pluck(:id)
  end

  def self.patient_card?(contact, identity)
    identity[:card] || contact.patient_scheduling_appointments.exists?
  end

  def self.conflicting_identities?(source, target)
    %i[code iin].any? { |key| source[key].present? && target[key].present? && source[key] != target[key] }
  end

  def self.matching_identity?(source, target)
    %i[code iin].any? { |key| source[key].present? && source[key] == target[key] }
  end

  def self.identity(contact)
    attributes = contact.custom_attributes.to_h
    iin = attributes['iin'].presence || attributes['medelement_iin'].presence || contact.identifier
    {
      code: attributes['medelement_patient_code'].to_s.presence,
      iin: Scheduling::IinValidator.valid?(iin) ? Scheduling::IinValidator.normalize(iin) : nil,
      card: attributes[Integrations::Medelement::PatientContactBinding::CARD_KEY] == true
    }
  end
  private_class_method :identity, :conflicting_identities?, :matching_identity?, :patient_card?
end
