class Integrations::Medelement::ProviderScope
  COMPANY_KEYS = %w[COMPANY_CODE company_code companyCode].freeze
  PATIENT_CODE_KEYS = %w[PROFILE_CODE PATIENT_CODE profile_code patient_code].freeze

  class MismatchError < StandardError; end

  class << self
    def validate!(payload, organization_id:)
      expected = organization_id.to_s.presence
      raise MismatchError, 'Medelement organization is not configured' if expected.blank?

      company_codes(payload).each do |company_code|
        raise MismatchError, 'Medelement response belongs to another organization' unless company_code == expected
      end
      payload
    end

    def validate_write!(payload, organization_id:)
      expected = organization_id.to_s.presence
      raise MismatchError, 'Medelement organization is not configured' if expected.blank?

      codes = company_codes(payload)
      raise MismatchError, 'Medelement write organization does not match configuration' unless codes.present? && codes.all?(expected)

      payload
    end

    def validate_patient!(payload, organization_id:, expected_patient_code: nil, expected_iin: nil, expected_phone_numbers: [])
      validate!(payload, organization_id: organization_id)
      validate_patient_code!(payload, expected_patient_code)
      validate_iin!(payload, expected_iin)
      return payload if company_codes(payload).present?
      return payload if expected_patient_code.present?
      return payload if matching_iin?(payload, expected_iin)
      return payload if matching_phone?(payload, expected_phone_numbers)

      raise MismatchError, 'Medelement patient organization cannot be verified'
    end

    private

    def company_codes(value)
      case value
      when Hash
        own_codes = COMPANY_KEYS.filter_map { |key| value[key].to_s.presence }
        own_codes + value.values.flat_map { |child| company_codes(child) }
      when Array
        value.flat_map { |child| company_codes(child) }
      else
        []
      end
    end

    def validate_patient_code!(payload, expected_patient_code)
      return if expected_patient_code.blank?

      actual = PATIENT_CODE_KEYS.filter_map { |key| payload.to_h[key].to_s.presence }.first
      raise MismatchError, 'Medelement patient reference cannot be verified' unless actual == expected_patient_code.to_s
    end

    def validate_iin!(payload, expected_iin)
      return if expected_iin.blank?
      return if matching_iin?(payload, expected_iin)

      raise MismatchError, 'Medelement patient IIN cannot be verified'
    end

    def matching_iin?(payload, expected_iin)
      expected = normalize_digits(expected_iin)
      return false if expected.blank?

      normalize_digits(payload.to_h['IIN'] || payload.to_h['iin']) == expected
    end

    def matching_phone?(payload, expected_phone_numbers)
      expected = Array(expected_phone_numbers).filter_map do |value|
        Integrations::Medelement::PhoneNumber.normalize(value)
      end
      return false if expected.empty?

      expected.intersect?(Integrations::Medelement::PhoneNumber.patient_phones(payload))
    end

    def normalize_digits(value)
      value.to_s.gsub(/\D/, '').presence
    end
  end
end
