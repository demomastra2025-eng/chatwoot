# frozen_string_literal: true

require 'openssl'

module Compliance::TombstoneHasher
  KINDS = %w[phone iin email medelement_patient_code].freeze
  DOMAIN_PREFIX = 'onelink:tombstone:v1'

  module_function

  def digest(account_id:, kind:, raw_value:)
    kind_str = kind.to_s
    return nil if account_id.blank? || KINDS.exclude?(kind_str)

    normalized = normalize(kind_str, raw_value)
    return nil if normalized.blank?

    OpenSSL::HMAC.hexdigest('SHA256', secret_material, "#{DOMAIN_PREFIX}:#{account_id.to_i}:#{kind_str}:#{normalized}")
  end

  def normalize(kind, raw_value)
    case kind.to_s
    when 'phone' then normalize_phone(raw_value)
    when 'iin' then normalize_iin(raw_value)
    when 'email' then normalize_email(raw_value)
    when 'medelement_patient_code' then normalize_code(raw_value)
    end
  end

  def extract_contact_identifiers(contact)
    return [] if contact.blank? || contact.account_id.blank?

    account_id = contact.account_id
    attrs = contact.custom_attributes.to_h
    phones = [contact.phone_number, *Array(attrs['secondary_phones'])]
    phones.concat(ContactPhone.where(contact_id: contact.id).pluck(:phone_number)) if defined?(ContactPhone) && contact.id.present?
    iins = [contact.identifier, attrs['iin'], attrs['medelement_iin']]
    emails = [contact.email]
    codes = [attrs['medelement_patient_code'], *Array(attrs['medelement_merged_patient_codes'])]

    build_entries(account_id, phone: phones, iin: iins, email: emails, medelement_patient_code: codes)
  end

  def extract_medelement_identifiers(account_id:, patient: nil, patient_code: nil, reception: nil)
    return [] if account_id.blank?

    p_hash = patient.is_a?(Hash) ? patient : {}
    r_hash = reception.is_a?(Hash) ? reception : {}
    codes = [
      patient_code,
      p_hash['PROFILE_CODE'], p_hash['PATIENT_CODE'],
      r_hash['PROFILE_CODE'], r_hash['PATIENT_CODE']
    ]
    iins = [p_hash['IIN'], r_hash['IIN'], r_hash['PATIENT_IIN']]
    emails = [p_hash['PATIENT_EMAIL'], r_hash['PATIENT_EMAIL']]
    phones = []
    phones.concat(Integrations::Medelement::PhoneNumber.patient_phones(p_hash)) if p_hash.present? && defined?(Integrations::Medelement::PhoneNumber)
    [r_hash['PATIENT_PHONE'], r_hash['PHONE'], r_hash['MOBILE_PHONE']].compact_blank.each { |ph| phones << ph }

    build_entries(account_id, phone: phones, iin: iins, email: emails, medelement_patient_code: codes)
  end

  def build_entries(account_id, mapping)
    entries = []
    mapping.each do |kind, values|
      Array(values).each do |raw|
        hmac = digest(account_id: account_id, kind: kind, raw_value: raw)
        entries << { kind: kind.to_s, hmac: hmac } if hmac.present?
      end
    end
    entries.uniq { |entry| [entry[:kind], entry[:hmac]] }
  end

  def normalize_phone(raw_value)
    str = raw_value.to_s.strip
    return nil if str.blank?

    digits = str.gsub(/\D/, '')
    return "+7#{digits[1..]}" if kz_eleven_digits?(digits)

    normalize_external_phone(str, digits)
  rescue StandardError
    nil
  end

  def kz_eleven_digits?(digits)
    digits.length == 11 && digits.start_with?('77', '87')
  end

  def normalize_external_phone(str, digits)
    if defined?(Contacts::PhoneNumberNormalizer)
      normalized = Contacts::PhoneNumberNormalizer.normalize(str)
      return normalized if normalized.present? && normalized.start_with?('+')
    end
    "+#{digits}" if str.start_with?('+') && digits.length.between?(10, 15)
  end

  def normalize_iin(raw_value)
    digits = raw_value.to_s.gsub(/\D/, '')
    digits if digits.match?(/\A\d{12}\z/)
  end

  def normalize_email(raw_value)
    email = raw_value.to_s.strip.downcase
    email if email.present? && email.include?('@')
  end

  def normalize_code(raw_value)
    code = raw_value.to_s.strip
    code.presence
  end

  def secret_material
    key = ENV['COMPLIANCE_TOMBSTONE_HMAC_SECRET'].to_s.presence || Rails.application.secret_key_base.to_s
    return key if key.present?
    raise 'Secret key is required for Compliance::TombstoneHasher' if Rails.env.production?

    'onelink-nonprod-compliance-tombstone-key'
  end

  private_class_method :normalize_phone, :kz_eleven_digits?, :normalize_external_phone,
                       :normalize_iin, :normalize_email, :normalize_code, :secret_material
end
