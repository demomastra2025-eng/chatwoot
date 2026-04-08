class Integrations::Medelement::ContactResolverService
  FRESHNESS_WINDOW = 24.hours
  PHONE_FIELDS = %w[PATIENT_PHONE_2_STR PATIENT_PHONE_1_STR PATIENT_PHONE_3_STR PATIENT_PHONE_4_STR].freeze
  GENDER_MAP = {
    '1' => 'female',
    '2' => 'male'
  }.freeze

  def initialize(account:, client:)
    @account = account
    @client = client
  end

  def sync_patient!(patient_code)
    existing_contact = find_by_patient_code(patient_code)
    return existing_contact if fresh?(existing_contact)

    patient = client.get_patient(patient_code: patient_code)
    return existing_contact if patient.blank?

    upsert_contact(patient)
  end

  private

  attr_reader :account, :client

  def contact_for_lookup(patient_code:, iin:, email:)
    find_by_patient_code(patient_code) ||
      find_by_identifier(iin) ||
      find_by_email(email)
  end

  def find_by_email(email)
    return if email.blank?

    account.contacts.find_by(email: email.downcase)
  end

  def find_by_identifier(identifier)
    return if identifier.blank?

    account.contacts.find_by(identifier: identifier)
  end

  def find_by_patient_code(patient_code)
    account.contacts.find_by("custom_attributes ->> 'medelement_patient_code' = ?", patient_code.to_s)
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

  def main_phone(patient)
    PHONE_FIELDS.filter_map { |field| normalize_phone(patient[field]) }.first
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

  def normalize_phone(raw)
    return if raw.blank?

    phone = raw.to_s.strip
    digits = phone.gsub(/\D/, '')
    return "+7#{digits}" if digits.length == 10
    return "+7#{digits[1..10]}" if digits.length >= 11 && %w[7 8].include?(digits[0])
    return phone if phone.match?(/\+[1-9]\d{7,14}\z/)

    nil
  end

  def safe_unique_value(contact, attribute, value)
    return if value.blank?

    existing = account.contacts.where(attribute => value).where.not(id: contact.id).first
    return if existing.present?

    value
  end

  def secondary_phones(patient, main_phone_value)
    PHONE_FIELDS.filter_map { |field| normalize_phone(patient[field]) }.uniq - Array(main_phone_value)
  end

  def upsert_contact(patient)
    patient_code = patient['PROFILE_CODE'].presence || patient['PATIENT_CODE'].presence
    iin = normalize_iin(patient['IIN'])
    email = patient['PATIENT_EMAIL'].to_s.downcase.presence
    contact = contact_for_lookup(patient_code: patient_code, iin: iin, email: email) || account.contacts.new

    phone = main_phone(patient)
    phone_conflict_comment = nil
    if phone.present?
      conflicting_contact = account.contacts.where(phone_number: phone).where.not(id: contact.id).first
      if conflicting_contact.present?
        phone_conflict_comment = "Phone #{phone} already belongs to contact ##{conflicting_contact.id}"
        phone = nil
      end
    end

    contact.skip_runtime_events = true
    contact.account ||= account
    contact.name = patient['FULLNAME'].presence || [patient['LASTNAME'], patient['NAME'], patient['MIDDLENAME']].compact_blank.join(' ')
    contact.last_name = patient['LASTNAME'].to_s if contact.respond_to?(:last_name=)
    contact.middle_name = patient['MIDDLENAME'].to_s if contact.respond_to?(:middle_name=)
    contact.email = safe_unique_value(contact, :email, email) || contact.email
    contact.phone_number = safe_unique_value(contact, :phone_number, phone) || contact.phone_number
    contact.identifier = safe_unique_value(contact, :identifier, iin) || contact.identifier
    contact.additional_attributes = (contact.additional_attributes || {}).deep_stringify_keys.reverse_merge(
      'country' => 'Kazakhstan',
      'country_code' => 'KZ'
    )
    contact.custom_attributes = contact.custom_attributes.merge(
      'address' => patient['FULL_ADDRESS'].to_s.presence,
      'birth_date' => normalize_birth_date(patient['BIRTHDAY']),
      'gender' => gender_value(patient),
      'iin' => iin,
      'medelement_last_synced_at' => Time.current.iso8601,
      'medelement_patient_code' => patient_code.to_s,
      'phone_conflict_comment' => phone_conflict_comment,
      'secondary_phones' => secondary_phones(patient, phone)
    ).compact
    contact.save!
    contact
  end
end
