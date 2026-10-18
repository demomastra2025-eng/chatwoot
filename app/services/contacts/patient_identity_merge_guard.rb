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
  # into another contact or a contact into it, unless both sides carry the same confirmed provider identity
  # or represent duplicate cards of the same person without conflicting identities.
  def self.explicit_merge_allowed?(base_contact:, mergee_contact:)
    return false if base_contact.account_id != mergee_contact.account_id

    base = identity(base_contact)
    mergee = identity(mergee_contact)
    return false if conflicting_iin?(mergee, base)
    return true if matching_identity?(mergee, base)
    return true if same_person_demographics?(base_contact, mergee_contact)
    return false if conflicting_code?(mergee, base)

    !patient_card?(base_contact, base) && !patient_card?(mergee_contact, mergee)
  end

  def self.same_person_cards?(first_contact, second_contact)
    return false if first_contact.blank? || second_contact.blank?
    return false if first_contact.account_id != second_contact.account_id || first_contact.id == second_contact.id

    first = identity(first_contact)
    second = identity(second_contact)
    return false if conflicting_iin?(first, second)
    return true if matching_identity?(first, second)

    same_person_demographics?(first_contact, second_contact)
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
    conflicting_code?(source, target) || conflicting_iin?(source, target)
  end

  def self.conflicting_code?(source, target)
    conflicting_value?(source[:code], target[:code])
  end

  def self.conflicting_iin?(source, target)
    conflicting_value?(source[:iin], target[:iin])
  end

  def self.conflicting_value?(first, second)
    first.present? && second.present? && first != second
  end

  def self.matching_identity?(source, target)
    %i[code iin].any? { |key| source[key].present? && source[key] == target[key] }
  end

  def self.same_person_demographics?(first_contact, second_contact)
    first = demographic_identity(first_contact)
    second = demographic_identity(second_contact)
    return false if conflicting_value?(first[:birth_date], second[:birth_date])

    matching_full_name?(first, second) || matching_first_name_and_birth_date?(first, second)
  end

  def self.matching_full_name?(first, second)
    first_parts = [first[:first_name], first[:last_name]].compact_blank
    second_parts = [second[:first_name], second[:last_name]].compact_blank
    first_parts.size == 2 && second_parts.size == 2 && first_parts.sort == second_parts.sort
  end

  def self.matching_first_name_and_birth_date?(first, second)
    return false if first[:first_name].blank? || second[:first_name].blank?
    return false if first[:birth_date].blank? || first[:birth_date] != second[:birth_date]
    return false if conflicting_value?(first[:last_name], second[:last_name])

    first[:first_name] == second[:first_name]
  end

  def self.demographic_identity(contact)
    attrs = contact.custom_attributes.to_h
    first_name, last_name = extract_first_and_last_name(contact, attrs)
    {
      first_name: normalize_name_part(first_name),
      last_name: normalize_name_part(last_name),
      birth_date: normalize_birth_date(attrs['birth_date'].presence || attrs['medelement_birth_date'].presence)
    }
  end

  def self.extract_first_and_last_name(contact, attrs)
    first = attrs['medelement_first_name'].presence || contact.name.to_s.strip.presence
    last = attrs['medelement_last_name'].presence || contact.last_name.to_s.strip.presence
    if last.blank? && first.present?
      tokens = first.split(/\s+/).compact_blank
      return [tokens.first, tokens.second] if tokens.size == 2 && !default_placeholder_name?(first)
    end
    [first, last]
  end

  def self.default_placeholder_name?(value)
    value.to_s.strip.casecmp('John Doe').zero? || value.to_s.strip.casecmp('MyString').zero?
  end

  def self.normalize_name_part(value)
    cleaned = value.to_s.unicode_normalize(:nfkc).downcase.tr('ё', 'е').squish
    return if cleaned.length < 2 || cleaned.match?(/\d/)

    cleaned
  end

  def self.normalize_birth_date(value)
    return if value.blank?

    Date.parse(value.to_s).iso8601
  rescue ArgumentError
    nil
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
  private_class_method :identity, :conflicting_identities?, :conflicting_code?, :conflicting_iin?,
                       :conflicting_value?, :matching_identity?, :same_person_demographics?,
                       :matching_full_name?, :matching_first_name_and_birth_date?, :demographic_identity,
                       :extract_first_and_last_name, :default_placeholder_name?, :normalize_name_part,
                       :normalize_birth_date, :patient_card?
end
