module Scheduling::IinValidator
  module_function

  ATTRIBUTE_KEY = 'iin'.freeze
  FIRST_WEIGHTS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].freeze
  SECOND_WEIGHTS = [3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2].freeze

  # Whether the account identifies its patients by an IIN: its contact attributes hold one (the "iin" attribute that the clinic-system
  # setup creates, Integrations::Medelement::ContactCustomAttributesSetupService, or the clinic made itself). The rules and the checks
  # that ask a patient for an IIN or refuse a wrong one apply there only; the contacts of any other account keep whatever identifier
  # their website or CRM gives them. The feature flag of scheduling says nothing: it is on for every new account.
  def in_use?(account)
    account.present? && account.custom_attribute_definitions.contact_attribute.exists?(attribute_key: ATTRIBUTE_KEY)
  end

  def iin_like?(value)
    normalize(value).to_s.length == 12
  end

  def normalize(value)
    digits = value.to_s.gsub(/\D/, '')
    digits.presence
  end

  def valid?(value)
    iin = normalize(value)
    return false unless iin&.match?(/\A\d{12}\z/)

    digits = iin.chars.map(&:to_i)
    checksum = weighted_checksum(digits, FIRST_WEIGHTS)
    checksum = weighted_checksum(digits, SECOND_WEIGHTS) if checksum == 10
    checksum = 0 if checksum == 10

    checksum == digits.last
  end

  def validate!(value)
    normalized = normalize(value)
    return value.to_s.strip.presence unless iin_like?(value)
    return normalized if valid?(normalized)

    raise Scheduling::Error.new(
      code: 'INVALID_IIN',
      message: 'Invalid IIN',
      status: :unprocessable_content
    )
  end

  # The IIN a patient-facing agent may write to a card: 12 digits with the check digit, as the digits only. Anything else is refused,
  # a phone number included (the eval of 27.10: a payment phone number the patient sent was read as the ID number and a card was raised
  # to update it, because the tool took any text). Nil and blank are no IIN to write: the caller leaves the field alone.
  def require_valid!(value)
    return if value.to_s.strip.empty?

    normalized = normalize(value)
    return normalized if valid?(normalized)

    raise Scheduling::Error.new(
      code: 'INVALID_IIN',
      message: 'Invalid IIN: an IIN is 12 digits with a check digit, a phone number is not an IIN; ask the patient for the IIN',
      status: :unprocessable_content
    )
  end

  # The IIN a tool call would write to a patient card: the identifier, and the iin of the custom attributes (a hash or its JSON text).
  # Both must be an IIN (see #require_valid!), so a wrong value cannot be written the other way round. Returns the identifier as the
  # digits only, nil when the call writes none.
  def require_valid_in!(identifier: nil, custom_attributes: nil)
    attributes = custom_attributes.is_a?(String) ? parsed_attributes(custom_attributes) : custom_attributes.to_h
    require_valid!(attributes.with_indifferent_access[:iin])
    require_valid!(identifier)
  end

  def parsed_attributes(text)
    parsed = JSON.parse(text)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def weighted_checksum(digits, weights)
    weights.each_with_index.sum { |weight, index| digits[index] * weight } % 11
  end
  private_class_method :weighted_checksum, :parsed_attributes
end
