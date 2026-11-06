class Captain::Tools::Agent::PatientBookingContext
  PATRONYMIC_SUFFIX = /(?:ович|евич|овна|евна|ична|қызы|кызы|ұлы|улы|ovich|evna|kyzy|uly)\z/iu
  SURNAME_ONLY_SUFFIX = /(?:ова|ева|ёва|ина|ов|ев|ёв|ин|ская|ский|цкая|цкий|ко|дзе|швили|ян|ova|eva|ina|ov|ev|skaya|skiy)\z/iu

  def initialize(assistant:, conversation:, patient:)
    @assistant = assistant
    @conversation = conversation
    @patient = normalize_unmasked_patient_names(
      patient.to_h.deep_symbolize_keys.slice(:first_name, :last_name, :middle_name, :iin, :birth_date, :gender, :phone)
    )
  end

  def perform
    validate_booking_inputs!
    card = existing_patient || create_patient
    {
      patient_contact_id: card.id,
      patient_selection_token: Captain::Tools::Agent::AppointmentAccess.issue_patient_selection(
        assistant: assistant, contact: conversation.contact, patient_id: card.id
      )
    }
  end

  private

  attr_reader :assistant, :conversation, :patient

  def validate_booking_inputs!
    raise ArgumentError, 'Current conversation is not available' unless conversation&.account_id == assistant.account_id
    raise ArgumentError, 'Patient first and last name are required' if patient[:first_name].blank? || patient[:last_name].blank?
    raise ArgumentError, 'Invalid patient IIN' if patient[:iin].present? && !Scheduling::IinValidator.valid?(patient[:iin])

    validate_birth_date!
  end

  def normalize_unmasked_patient_names(attrs)
    combined = single_field_multiword_name(attrs[:first_name].to_s.squish, attrs[:last_name].to_s.squish)
    return attrs if combined.blank?

    parts = combined.split(/\s+/)
    assign_split_name_parts!(attrs, parts) if parts.size >= 2
    attrs
  end

  def single_field_multiword_name(first, last)
    return first if first.include?(' ') && (last.blank? || last.casecmp?(first))
    return last if last.include?(' ') && first.blank?

    nil
  end

  def assign_split_name_parts!(attrs, parts)
    return assign_two_part_name!(attrs, parts) if parts.size == 2

    first_idx, last_idx = parts[2].match?(PATRONYMIC_SUFFIX) ? [1, 0] : [0, 1]
    attrs[:first_name] = parts[first_idx]
    attrs[:last_name] = parts[last_idx]
    attrs[:middle_name] = parts[2..].join(' ') if attrs[:middle_name].blank?
  end

  def assign_two_part_name!(attrs, parts)
    return if align_with_conversation_contact!(attrs, parts)
    return if assign_female_and_male_pair!(attrs, parts)

    surname_first = recognized_surname?(parts[0]) && !recognized_surname?(parts[1])
    attrs[:first_name] = surname_first ? parts[1] : parts[0]
    attrs[:last_name] = surname_first ? parts[0] : parts[1]
  end

  def align_with_conversation_contact!(attrs, parts)
    contact = conversation&.contact
    c_first = contact.try(:name).to_s.squish
    c_last = contact.try(:last_name).to_s.squish
    return false unless [c_first, c_last].all?(&:present?) && same_two_word_pair?(parts[0], parts[1], c_first, c_last)

    attrs[:first_name] = c_first
    attrs[:last_name] = c_last
    true
  end

  def same_two_word_pair?(word_a, word_b, ref_a, ref_b)
    [word_a, word_b].map { |w| w.to_s.downcase }.sort == [ref_a, ref_b].map { |w| w.to_s.downcase }.sort
  end

  def assign_female_and_male_pair!(attrs, parts)
    return false unless defined?(Llm::PiiNameLexicon)

    f0 = Llm::PiiNameLexicon.female_first_name?(parts[0])
    f1 = Llm::PiiNameLexicon.female_first_name?(parts[1])
    return false if f0 == f1

    attrs[:first_name] = f0 ? parts[0] : parts[1]
    attrs[:last_name] = f0 ? parts[1] : parts[0]
    true
  end

  def recognized_surname?(word)
    word.to_s.match?(SURNAME_ONLY_SUFFIX) || (defined?(Llm::PiiNameLexicon) && Llm::PiiNameLexicon.last_name?(word))
  end

  def policy = Integrations::Medelement::AppointmentPatientIdentity

  def existing_patient
    iin = Scheduling::IinValidator.normalize(patient[:iin])
    return if iin.blank?

    card = find_single_patient_card_by_iin(iin)
    return unless card

    verify_existing_patient_card!(card)
    card
  end

  def find_single_patient_card_by_iin(iin)
    candidates = assistant.account.contacts.where(
      "identifier = :iin OR custom_attributes ->> 'iin' = :iin OR custom_attributes ->> 'medelement_iin' = :iin", iin: iin
    ).select { |card| Contacts::SharedPhone.recorded_patient_identity?(card, iin) }
    raise ArgumentError, 'Several patient cards match; clarify the patient with the clinic' if candidates.many?

    candidates.first
  end

  def verify_existing_patient_card!(card)
    recorded = policy.contact_names(card)
    if same_two_word_pair?(patient[:first_name], patient[:last_name], recorded['first_name'], recorded['last_name'])
      patient[:first_name] = recorded['first_name']
      patient[:last_name] = recorded['last_name']
    end
    identity = patient.merge(middle_name: patient.fetch(:middle_name, recorded['middle_name']))
    raise ArgumentError, 'Patient name does not match the recorded IIN' unless policy.names_match?(identity, card)

    verify_recorded_birth_date!(card)
    record_verified_patient(card)
  end

  def record_verified_patient(card)
    return unless defined?(Llm::PiiShadowAuditor)

    Llm::PiiShadowAuditor.record_verified_patient!(contact: card, account_id: assistant.account_id)
  end

  def verify_recorded_birth_date!(card)
    attrs = card.custom_attributes.to_h
    recorded_birth_date = attrs['medelement_birth_date'].presence || attrs['birth_date'].presence
    return if patient[:birth_date].blank? || recorded_birth_date.blank?
    return if patient[:birth_date] == recorded_birth_date.to_s

    raise ArgumentError, 'Patient birth date does not match the recorded card'
  end

  def create_patient
    fingerprint = Digest::SHA256.hexdigest(JSON.generate(patient.sort.to_h))
    Scheduling::PatientContactCreationService.new(
      account: assistant.account, contact: conversation.contact,
      params: patient.merge(conversation_id: conversation.id,
                            idempotency_key: "captain:#{assistant.id}:#{conversation.id}:#{fingerprint}")
    ).perform
  end

  def validate_birth_date!
    return if patient[:birth_date].blank?

    value = patient[:birth_date].to_s
    raise ArgumentError, 'Patient birth date must use YYYY-MM-DD' unless value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value)
    patient[:birth_date] = value
  rescue Date::Error
    raise ArgumentError, 'Invalid patient birth date'
  end
end
