class Integrations::Medelement::PhoneNumber
  PATIENT_PHONE_FIELDS = %w[
    PATIENT_PHONE_2_STR PATIENT_PHONE_2
    PATIENT_PHONE_1_STR PATIENT_PHONE_1
    PATIENT_PHONE_3_STR PATIENT_PHONE_3
    PATIENT_PHONE_4_STR PATIENT_PHONE_4
    PHONES_STR
  ].freeze

  attr_reader :e164

  def initialize(raw_phone)
    @e164 = self.class.normalize(raw_phone)
    raise ArgumentError, 'phone_number must be a Kazakhstan E.164 number' if e164.blank?
  end

  def query(skip: 0)
    URI.encode_www_form(
      [
        ['patient_phone_2[0]', components[0]],
        ['patient_phone_2[1]', components[1]],
        ['patient_phone_2[2]', components[2]],
        ['skip', skip]
      ]
    )
  end

  def components
    digits = e164.delete_prefix('+')
    [digits[0], digits[1, 3], digits[4, 7]]
  end

  def matches_patient?(patient)
    self.class.patient_phones(patient).include?(e164)
  end

  class << self
    def normalize(raw_phone)
      digits = raw_phone.to_s.gsub(/\D/, '')
      digits = "7#{digits}" if digits.length == 10
      digits = "7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
      "+#{digits}" if digits.match?(/\A7\d{10}\z/)
    end

    def extract(raw_value)
      value = raw_value.is_a?(Array) ? raw_value.join : raw_value.to_s
      value.scan(/(?:\+?7|8)[\d\s()xX\-]{9,}/).filter_map do |candidate|
        normalize(candidate)
      end
    end

    def patient_phones(patient)
      PATIENT_PHONE_FIELDS.flat_map { |field| extract(patient[field]) }.uniq
    end

    def contact_phones(contact)
      return [] if contact.blank?

      values = [contact.phone_number, *Array(contact.custom_attributes.to_h['secondary_phones'])]
      values.flat_map { |value| extract(value).presence || Array(normalize(value)) }.uniq
    end
  end
end
