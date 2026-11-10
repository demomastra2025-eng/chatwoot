# frozen_string_literal: true

class Whatsapp::Flows::BookingClientValidator
  DOTTED_DATE_FORMAT = /\A(\d{2})\.(\d{2})\.(\d{4})\z/
  BASIC_PHONE_DIGITS_MIN = 7

  def initialize(account:, resource:, locale:, contact: nil, clinic_preset: nil)
    @account = account
    @resource = resource
    @copy = Whatsapp::Flows::BookingFlowCopy.for_locale(locale, account: account)
    @contact = contact
    @clinic_config = Whatsapp::Flows::ClinicProfile.config_for(account: account, preset: clinic_preset)
  end

  def field_flags
    {
      show_visit_reason: @clinic_config[:show_visit_reason] == true,
      visit_reasons: visit_reasons_data_source,
      show_last_name: true,
      require_last_name: require_last_name?,
      show_middle_name: require_middle_name?,
      require_middle_name: require_middle_name?,
      show_birth_date: show_birth_date?,
      require_birth_date: require_birth_date?,
      show_iin: show_iin?,
      require_iin: require_iin?
    }
  end

  def prefill_values(submitted = {})
    submitted = submitted.to_h.with_indifferent_access
    defaults = contact_defaults
    {
      init_visit_reason: submitted[:visit_reason].presence || @clinic_config[:default_visit_reason].to_s,
      init_first_name: submitted[:client_first_name].presence || defaults[:first_name],
      init_last_name: submitted[:client_last_name].presence || defaults[:last_name],
      init_middle_name: submitted[:client_middle_name].presence || defaults[:middle_name],
      init_phone: submitted[:client_phone].presence || defaults[:phone],
      init_birth_date: submitted[:client_birth_date].presence || defaults[:birth_date],
      init_iin: submitted[:client_iin].presence || defaults[:iin],
      init_notes: submitted[:notes].to_s
    }
  end

  def validate_submission(raw_data)
    fields = normalize_raw_submission(raw_data)
    error = submission_error(fields)
    return { valid: false, error: error } if error.present?

    { valid: true, attributes: build_validated_attributes(fields) }
  end

  private

  attr_reader :account, :resource, :copy, :contact

  def visit_reasons_data_source
    reasons = Array(@clinic_config[:visit_reasons])
    return [{ id: 'none', title: '-', description: '' }] if reasons.empty?

    reasons
  end

  def normalize_raw_submission(raw_data)
    data = raw_data.to_h.with_indifferent_access
    {
      visit_reason: clean_text(data[:visit_reason]),
      first_name: clean_text(data[:client_first_name]),
      last_name: clean_text(data[:client_last_name]),
      middle_name: clean_text(data[:client_middle_name]),
      phone: clean_text(data[:client_phone]),
      birth_date: clean_text(data[:client_birth_date]),
      iin: clean_text(data[:client_iin]),
      notes: clean_text(data[:notes])
    }
  end

  def submission_error(fields)
    validate_names(fields[:first_name], fields[:last_name], fields[:middle_name]) ||
      validate_phone(fields[:phone]) ||
      validate_birth_date(fields[:birth_date]) ||
      validate_iin(fields[:iin])
  end

  def build_validated_attributes(fields)
    {
      visit_reason: fields[:visit_reason].presence,
      client_first_name: fields[:first_name],
      client_last_name: fields[:last_name].presence,
      client_middle_name: fields[:middle_name].presence,
      client_phone: normalize_phone(fields[:phone]),
      client_birth_date: normalize_birth_date(fields[:birth_date]).presence,
      client_iin: Scheduling::IinValidator.normalize(fields[:iin]),
      notes: combine_visit_reason_and_notes(fields[:visit_reason], fields[:notes])
    }.compact
  end

  def combine_visit_reason_and_notes(visit_reason, raw_notes)
    notes_text = raw_notes.to_s.strip
    reason_code = visit_reason.to_s.strip
    return notes_text.presence if reason_code.blank? || reason_code == 'none'

    reason_title = Whatsapp::Flows::ClinicProfile.visit_reason_title(account, reason_code)
    return notes_text.presence if reason_title.blank?

    prefix = "[#{reason_title}]"
    return notes_text if notes_text.start_with?(prefix)

    notes_text.present? ? "#{prefix} #{notes_text}" : prefix
  end

  def validate_names(first_name, last_name, middle_name)
    return copy[:first_name_required] if first_name.blank?
    return copy[:last_name_required] if require_last_name? && last_name.blank?
    return copy[:middle_name_required] if require_middle_name? && middle_name.blank?

    nil
  end

  def validate_phone(raw_phone)
    digits = raw_phone.to_s.gsub(/\D/, '')
    return copy[:phone_required] if digits.length < BASIC_PHONE_DIGITS_MIN

    if medelement_resource? && !identified_medelement_patient? &&
       Integrations::Medelement::PhoneNumber.normalize(raw_phone).blank?
      return copy[:kz_phone_required]
    end

    nil
  end

  def validate_birth_date(raw_birth_date)
    return (require_birth_date? ? copy[:birth_date_required] : nil) if raw_birth_date.blank?

    normalized = normalize_birth_date(raw_birth_date)
    return nil if normalized.present? && Scheduling::BirthDate.valid?(normalized, plain: true)

    copy[:birth_date_invalid]
  end

  def validate_iin(raw_iin)
    return (require_iin? ? copy[:iin_required] : nil) if raw_iin.blank?
    return nil if Scheduling::IinValidator.valid?(raw_iin)

    copy[:iin_invalid]
  end

  def normalize_birth_date(value)
    text = value.to_s.strip
    return '' if text.empty?

    match = DOTTED_DATE_FORMAT.match(text)
    match ? "#{match[3]}-#{match[2]}-#{match[1]}" : text
  end

  def normalize_phone(raw_phone)
    if medelement_resource?
      normalized_kz = Integrations::Medelement::PhoneNumber.normalize(raw_phone)
      return normalized_kz if normalized_kz.present?
    end

    cleaned = raw_phone.to_s.strip
    cleaned.start_with?('+') ? "+#{cleaned.gsub(/\D/, '')}" : cleaned
  end

  def contact_defaults
    return empty_defaults unless valid_account_contact?

    attrs = contact.custom_attributes.to_h
    first_name, split_last = split_contact_name(contact, attrs)
    build_contact_defaults_hash(attrs, first_name, split_last)
  end

  def valid_account_contact?
    contact.present? && contact.account_id == account.id
  end

  def build_contact_defaults_hash(attrs, first_name, split_last)
    {
      first_name: first_name.to_s,
      last_name: (attrs['medelement_last_name'].presence || contact.try(:last_name).presence || split_last).to_s,
      middle_name: (attrs['medelement_middle_name'].presence || contact.try(:middle_name)).to_s,
      phone: contact.phone_number.to_s,
      birth_date: Scheduling::BirthDate.normalize(attrs['birth_date']).to_s,
      iin: extract_valid_contact_iin(contact, attrs)
    }
  end

  def split_contact_name(contact_record, attrs)
    med_first = attrs['medelement_first_name'].to_s.strip
    return [med_first, nil] if med_first.present?

    raw_name = contact_record.name.to_s.strip
    return ['', nil] if raw_name.blank? || raw_name.match?(/\A\+?\d[\d\s()-]+\z/)
    return [raw_name, nil] if contact_record.try(:last_name).present?

    parts = raw_name.split(/\s+/, 2)
    [parts[0].to_s, parts[1]]
  end

  def extract_valid_contact_iin(contact_record, attrs)
    candidate = attrs['iin'].presence || contact_record.identifier
    Scheduling::IinValidator.valid?(candidate) ? Scheduling::IinValidator.normalize(candidate) : ''
  end

  def empty_defaults
    { first_name: '', last_name: '', middle_name: '', phone: '', birth_date: '', iin: '' }
  end

  def medelement_resource?
    resource&.custom_attributes.to_h['medelement_specialist_code'].present?
  end

  def medelement_config
    return nil unless medelement_resource?

    @medelement_config ||= Integrations::Medelement::Configuration.for_account(account)
  end

  def identified_medelement_patient?
    contact.present? && contact.custom_attributes.to_h['medelement_patient_code'].present?
  end

  def require_last_name? = medelement_config&.require_patient_last_name? == true
  def require_middle_name? = medelement_config&.require_patient_middle_name? == true
  def require_birth_date? = medelement_config&.require_patient_birth_date? == true
  def show_birth_date? = require_birth_date? || @clinic_config[:force_show_birth_date] == true || contact_attribute_defined?('birth_date')
  def require_iin? = medelement_config&.require_patient_iin? == true
  def show_iin? = require_iin? || @clinic_config[:force_show_iin] == true || contact_attribute_defined?('iin')

  def contact_attribute_defined?(key)
    account.custom_attribute_definitions.exists?(
      attribute_model: :contact_attribute,
      attribute_key: key
    )
  end

  def clean_text(value)
    value.to_s.strip
  end
end
