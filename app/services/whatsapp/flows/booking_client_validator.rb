# frozen_string_literal: true

class Whatsapp::Flows::BookingClientValidator
  DOTTED_DATE_FORMAT = /\A(\d{2})\.(\d{2})\.(\d{4})\z/
  BASIC_PHONE_DIGITS_MIN = 7

  class << self
    def mask_name(raw_name)
      text = raw_name.to_s.strip
      return '' if text.empty?

      text.split(/\s+/).map { |word| mask_word(word) }.join(' ')
    end

    def mask_phone(raw_phone)
      text = raw_phone.to_s.strip
      return '' if text.empty?

      digits = text.gsub(/\D/, '')
      return "#{text[0]}***" if digits.length < 6

      prefix = text.start_with?('+') ? "+#{digits[0, 4]}" : digits[0, 4]
      suffix = digits[-2, 2]
      masked_len = [digits.length - 6, 3].max
      "#{prefix}#{'*' * masked_len}#{suffix}"
    end

    def mask_iin(raw_iin)
      digits = raw_iin.to_s.gsub(/\D/, '')
      return '' if digits.empty?
      return "#{digits[0, 2]}****" if digits.length < 8

      "#{digits[0, 4]}#{'*' * (digits.length - 6)}#{digits[-2, 2]}"
    end

    def mask_birth_date(raw_date)
      text = raw_date.to_s.strip
      return '' if text.empty?

      if (m = /\A(\d{4})-(\d{2})-(\d{2})\z/.match(text))
        "**.**.#{m[1]}"
      elsif (m = DOTTED_DATE_FORMAT.match(text))
        "**.**.#{m[3]}"
      else
        '**.**.****'
      end
    end

    def mask_client_attributes(attrs)
      data = attrs.to_h.with_indifferent_access
      {
        visit_reason: data[:visit_reason].presence,
        client_first_name: mask_name(data[:client_first_name]).presence,
        client_last_name: mask_name(data[:client_last_name]).presence,
        client_middle_name: mask_name(data[:client_middle_name]).presence,
        client_phone: mask_phone(data[:client_phone]).presence,
        client_birth_date: mask_birth_date(data[:client_birth_date]).presence,
        client_iin: mask_iin(data[:client_iin]).presence,
        notes: data[:notes].presence
      }.compact
    end

    private

    def mask_word(word)
      chars = word.chars
      return '' if chars.empty?
      return "#{chars[0]}*" if chars.length <= 2

      "#{chars.first}#{'*' * (chars.length - 2)}#{chars.last}"
    end
  end

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
    masked_defaults = masked_contact_defaults
    {
      init_visit_reason: submitted[:visit_reason].presence || @clinic_config[:default_visit_reason].to_s,
      init_first_name: submitted[:client_first_name].presence || masked_defaults[:first_name],
      init_last_name: submitted[:client_last_name].presence || masked_defaults[:last_name],
      init_middle_name: submitted[:client_middle_name].presence || masked_defaults[:middle_name],
      init_phone: submitted[:client_phone].presence || masked_defaults[:phone],
      init_birth_date: submitted[:client_birth_date].presence || masked_defaults[:birth_date],
      init_iin: submitted[:client_iin].presence || masked_defaults[:iin],
      init_notes: submitted[:notes].to_s
    }
  end

  def validate_submission(raw_data)
    fields = normalize_raw_submission(raw_data)
    error = submission_error(fields)
    return { valid: false, error: error } if error.present?

    validated = build_validated_attributes(fields)
    {
      valid: true,
      attributes: validated,
      masked_attributes: self.class.mask_client_attributes(validated)
    }
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
    defaults = contact_defaults
    {
      visit_reason: clean_text(data[:visit_reason]),
      first_name: unmask_if_unchanged(data[:client_first_name], defaults[:first_name]),
      last_name: unmask_if_unchanged(data[:client_last_name], defaults[:last_name]),
      middle_name: unmask_if_unchanged(data[:client_middle_name], defaults[:middle_name]),
      phone: unmask_if_unchanged(data[:client_phone], defaults[:phone]),
      birth_date: unmask_if_unchanged(data[:client_birth_date], defaults[:birth_date]),
      iin: unmask_if_unchanged(data[:client_iin], defaults[:iin]),
      notes: clean_text(data[:notes])
    }
  end

  def unmask_if_unchanged(raw_submitted, default_val)
    text = clean_text(raw_submitted)
    return default_val.to_s if text.include?('*') && default_val.present?

    text
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
    return copy[:first_name_required] if first_name.blank? || first_name.include?('*')
    return copy[:last_name_required] if require_last_name? && (last_name.blank? || last_name.include?('*'))
    return copy[:middle_name_required] if require_middle_name? && (middle_name.blank? || middle_name.include?('*'))

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
    return nil unless show_birth_date?

    normalized = normalize_birth_date(raw_birth_date)
    if normalized.blank?
      return copy[:birth_date_required] if require_birth_date?

      return nil
    end

    Scheduling::BirthDate.valid?(normalized, plain: true) ? nil : copy[:birth_date_invalid]
  end

  def validate_iin(raw_iin)
    return nil unless show_iin?

    if raw_iin.blank?
      return copy[:iin_required] if require_iin?

      return nil
    end

    Scheduling::IinValidator.valid?(raw_iin) ? nil : copy[:iin_invalid]
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

  def masked_contact_defaults
    defaults = contact_defaults
    {
      first_name: self.class.mask_name(defaults[:first_name]),
      last_name: self.class.mask_name(defaults[:last_name]),
      middle_name: self.class.mask_name(defaults[:middle_name]),
      phone: self.class.mask_phone(defaults[:phone]),
      birth_date: self.class.mask_birth_date(defaults[:birth_date]),
      iin: self.class.mask_iin(defaults[:iin])
    }
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
