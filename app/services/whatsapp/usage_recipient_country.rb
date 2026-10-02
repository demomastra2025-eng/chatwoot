class Whatsapp::UsageRecipientCountry
  E164_PATTERN = /\A\+?[1-9]\d{1,14}\z/

  def self.resolve(recipient_id)
    value = recipient_id.to_s
    return unless value.match?(E164_PATTERN)

    number = TelephoneNumber.parse(value.start_with?('+') ? value : "+#{value}")
    return unless number.valid?

    country_code = number.country&.country_id.to_s.upcase
    country_code if country_code.match?(/\A[A-Z]{2}\z/)
  end
end
