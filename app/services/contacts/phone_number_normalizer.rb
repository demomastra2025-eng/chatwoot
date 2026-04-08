class Contacts::PhoneNumberNormalizer
  E164_PATTERN = /\A\+[1-9]\d{1,14}\z/.freeze

  class << self
    def normalize(raw_value, default_country: nil)
      value = raw_value.to_s.strip
      return nil if value.blank?
      return value if e164?(value)

      value = normalize_trunk_prefix(value, default_country)
      return value if e164?(value)

      parsed = parse_number(value, default_country)
      return nil if parsed.blank?

      international_number = parsed&.international_number.to_s
      return nil if international_number.blank? || !parsed.valid?

      normalized_value = international_number.gsub(/[^\d+]/, '')
      e164?(normalized_value) ? normalized_value : nil
    rescue StandardError
      nil
    end

    private

    def e164?(value)
      value.match?(E164_PATTERN)
    end

    def normalized_country(country)
      country.to_s.downcase.to_sym
    end

    def parse_number(value, default_country)
      return TelephoneNumber.parse(value, normalized_country(default_country)) if default_country.present?
      return TelephoneNumber.parse(value) if value.start_with?('+')

      nil
    end

    def normalize_trunk_prefix(value, default_country)
      return value if default_country.blank?

      country = default_country.to_s.upcase
      return value unless %w[KZ RU].include?(country)

      digits = value.gsub(/\D/, '')
      return value if digits.blank?
      return "+7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
      return "+#{digits}" if digits.length == 11 && digits.start_with?('7')

      value
    end
  end
end
