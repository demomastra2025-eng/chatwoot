class Integrations::Medelement::ProviderScope
  COMPANY_KEYS = %w[COMPANY_CODE company_code companyCode].freeze

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
  end
end
