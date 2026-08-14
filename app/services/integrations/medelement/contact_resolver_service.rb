# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ContactResolverService
  FRESHNESS_WINDOW = 24.hours
  GENDER_MAP = {
    '1' => 'female',
    '2' => 'male'
  }.freeze

  def initialize(account:, client:, conflict_tracker: nil, organization_id: nil)
    @account = account
    @client = client
    @conflict_tracker = conflict_tracker
    @organization_id = organization_id
  end

  def sync_patient!(patient_code, preferred_contact: nil)
    existing_contact = find_by_patient_code(patient_code)
    return existing_contact if preferred_contact.nil? && fresh?(existing_contact)

    patient = client.get_patient(patient_code: patient_code)
    return existing_contact if patient.blank?

    Integrations::Medelement::ProviderScope.validate!(patient, organization_id: organization_id)
    return existing_contact if provider_read_models_conflict?(patient_code, patient, existing_contact)

    upsert_contact(patient, preferred_contact: preferred_contact)
  end

  def sync_patient_payload!(patient, preferred_contact:)
    patient_code = patient['PROFILE_CODE'].presence || patient['PATIENT_CODE'].presence
    Integrations::Medelement::ProviderScope.validate!(patient, organization_id: organization_id)
    return preferred_contact if patient_code.blank?
    return preferred_contact if provider_read_models_conflict?(patient_code, patient, preferred_contact)

    upsert_contact(patient, preferred_contact: preferred_contact)
  end

  private

  attr_reader :account, :client, :conflict_tracker, :organization_id

  def contact_for_lookup(patient_code:, iin:, email:, preferred_contact: nil)
    preferred_contact || find_by_patient_code(patient_code) ||
      find_by_identifier(iin) ||
      find_by_email(email)
  end

  def find_by_email(email)
    return if email.blank?

    account.contacts.from_email(email)
  end

  def find_by_identifier(identifier)
    return if identifier.blank?

    account.contacts.find_by(identifier: identifier)
  end

  def find_by_patient_code(patient_code)
    account.contacts.find_by("custom_attributes ->> 'medelement_patient_code' = ?", patient_code.to_s)
  end

  def provider_read_models_conflict?(patient_code, direct_patient, contact)
    Integrations::Medelement::PatientReadModelGuard.new(
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: organization_id
    ).conflict?(patient_code: patient_code, direct_patient: direct_patient, contact: contact)
  end

  def fresh?(contact)
    synced_at = contact&.custom_attributes&.dig('medelement_last_synced_at')
    return false if synced_at.blank?

    Time.zone.parse(synced_at.to_s) >= FRESHNESS_WINDOW.ago
  rescue ArgumentError, TypeError
    false
  end

  def gender_value(patient)
    GENDER_MAP[patient['GENDER'].to_s] || patient['GENDER_NAME'].to_s.presence || patient['GENDER'].to_s.presence
  end

  def normalize_birth_date(value)
    return if value.blank?

    Date.strptime(value.to_s, '%d.%m.%Y').iso8601
  rescue ArgumentError
    nil
  end

  def normalize_iin(value)
    return if value.blank?

    iin = value.to_s.gsub(/\D/, '')
    Scheduling::IinValidator.validate!(iin)
    iin
  rescue Scheduling::Error
    nil
  end

  def patient_first_name(patient)
    explicit_name = patient['NAME'].presence || patient['FIRSTNAME'].presence
    return explicit_name if explicit_name

    parts = patient['FULLNAME'].to_s.split
    parts.shift if patient['LASTNAME'].present? && parts.first == patient['LASTNAME'].to_s
    parts.pop if patient['MIDDLENAME'].present? && parts.last == patient['MIDDLENAME'].to_s
    parts.join(' ').presence
  end

  def safe_unique_value(contact, attribute, value)
    return if value.blank?

    existing = account.contacts.where(attribute => value).where.not(id: contact.id).first
    return if existing.present?

    value
  end

  def provider_phones(patient)
    Integrations::Medelement::PhoneNumber.patient_phones(patient)
  end

  def secondary_phones(contact, patient, primary_phone)
    existing = Integrations::Medelement::PhoneNumber.contact_phones(contact)
    (existing + provider_phones(patient)).uniq - Array(primary_phone)
  end

  def resolved_phone(contact, patient)
    phones = provider_phones(patient)
    source_phone = phones.first
    contact_phone = Integrations::Medelement::PhoneNumber.normalize(contact.phone_number)
    return [source_phone, contact_phone, nil] if source_phone.blank? && contact_phone.present?
    return existing_contact_phone_resolution(source_phone, contact_phone, phones) if contact_phone.present?

    new_contact_phone_resolution(contact, source_phone)
  end

  def existing_contact_phone_resolution(source_phone, contact_phone, provider_phone_values)
    return [source_phone, contact_phone, nil] if provider_phone_values.include?(contact_phone)

    [
      contact_phone,
      nil,
      "Medelement phone #{source_phone} differs from the current Contact phone"
    ]
  end

  def new_contact_phone_resolution(contact, source_phone)
    conflicting_contact = account.contacts.where(phone_number: source_phone).where.not(id: contact.id).first if source_phone.present?
    return [source_phone, source_phone, nil] if conflicting_contact.blank?

    [source_phone, nil, "Phone #{source_phone} already belongs to contact ##{conflicting_contact.id}"]
  end

  # Coordinates identity lookup, uniqueness checks and custom-attribute persistence as one unit.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def upsert_contact(patient, preferred_contact: nil)
    Integrations::Medelement::ProviderScope.validate!(patient, organization_id: organization_id)
    patient_code = patient['PROFILE_CODE'].presence || patient['PATIENT_CODE'].presence
    iin = normalize_iin(patient['IIN'])
    email = patient['PATIENT_EMAIL'].to_s.downcase.presence
    contact = contact_for_lookup(
      patient_code: patient_code,
      iin: iin,
      email: email,
      preferred_contact: preferred_contact
    ) || account.contacts.new

    _source_phone, phone, phone_conflict_comment = resolved_phone(contact, patient)
    primary_phone = Integrations::Medelement::PhoneNumber.normalize(phone.presence || contact.phone_number)

    contact.skip_runtime_events = true
    contact.account ||= account
    first_name = patient_first_name(patient)
    middle_name = patient['MIDDLENAME'].to_s.presence
    contact.name = first_name if first_name.present?
    contact.last_name = patient['LASTNAME'].to_s if contact.respond_to?(:last_name=) && patient['LASTNAME'].present?
    contact.middle_name = middle_name if contact.respond_to?(:middle_name=) && middle_name.present?
    contact.email = safe_unique_value(contact, :email, email) || contact.email
    contact.phone_number = safe_unique_value(contact, :phone_number, phone) || contact.phone_number
    contact.identifier = safe_unique_value(contact, :identifier, iin) || contact.identifier
    contact.additional_attributes = (contact.additional_attributes || {}).deep_stringify_keys.reverse_merge(
      'country' => 'Kazakhstan',
      'country_code' => 'KZ'
    )
    contact.custom_attributes = contact.custom_attributes.merge(
      provider_profile_attributes(patient, first_name, middle_name, iin)
    ).merge(
      'medelement_last_synced_at' => Time.current.iso8601,
      'medelement_patient_code' => patient_code.to_s,
      'phone_conflict_comment' => phone_conflict_comment,
      'secondary_phones' => secondary_phones(contact, patient, primary_phone)
    ).compact
    contact.save!
    record_phone_conflict(patient_code, contact, phone_conflict_comment) if phone_conflict_comment.present?
    contact
  end

  def provider_profile_attributes(patient, first_name, middle_name, iin)
    {
      'address' => patient['FULL_ADDRESS'].to_s.presence,
      'birth_date' => normalize_birth_date(patient['BIRTHDAY']),
      'gender' => gender_value(patient),
      'iin' => iin,
      'medelement_first_name' => first_name,
      'medelement_last_name' => patient['LASTNAME'].to_s.presence,
      'medelement_middle_name' => middle_name
    }.compact
  end

  def record_phone_conflict(patient_code, contact, comment)
    conflict_type = comment.include?('already belongs') ? 'phone_owned_by_another_contact' : 'phone_mismatch'
    conflicting_contact_id = comment[/contact #(\d+)/, 1]&.to_i
    conflict_tracker&.record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: conflict_type,
      entity_key: patient_code.presence || "contact:#{contact.id}",
      details: {
        contact_id: contact.id,
        conflicting_contact_id: conflicting_contact_id,
        reason: conflict_type
      }.compact
    )
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
end
# rubocop:enable Metrics/ClassLength
