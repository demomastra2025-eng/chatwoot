# frozen_string_literal: true

# rubocop:disable Metrics/ModuleLength
module Scheduling::IinValidator
  module_function

  ATTRIBUTE_KEY = 'iin'
  REDACTED_PLACEHOLDER = '[ИИН СКРЫТ]'
  FIRST_WEIGHTS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].freeze
  SECOND_WEIGHTS = [3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2].freeze
  CENTURY_BY_SEVENTH_DIGIT = { 3 => 1900, 4 => 1900, 5 => 2000, 6 => 2000 }.freeze
  SENSITIVE_ATTRIBUTE_KEY_PATTERN = /\A(?:medelement_)?iin\z/i
  DATA_URI_BASE64_PREFIX = %r{\Adata:[\w.+/-]+(?:;[\w.+=-]+)*;base64,}i
  INVALID_IIN_MESSAGE = 'Invalid IIN: an IIN is 12 digits with a check digit, a phone number is not an IIN; ask the patient for the IIN'
  IIN_DIGITS_FRAGMENT = '(?:\d{12}|\d{6}[ -](?:\d{6}|\d{3}[ -]\d{3})|\d{4}[ -]\d{4}[ -]\d{4}|' \
                        '\d{3}(?:[ -]\d{3}){3}|\d{2}[ -]\d{2}[ -]\d{2}[ -]\d{3}[ -]\d{3}|\d{2}(?:[ -]\d{2}){5})'
  LABELED_IIN_PATTERN = Regexp.new(
    '((?<![\p{L}\p{N}_])(?i:medelement_iin|client_identifier|ИИН|ЖСН|IIN)(?![\p{L}\p{N}_])(?:\\\\*["\'])?\s*[:=№#\/-]?\s*(?:\\\\*["\'])?)' \
    "(?<![+\\p{L}\\p{N}_])(#{IIN_DIGITS_FRAGMENT})(?![\\p{L}\\p{N}_])(?![ -]\\d)"
  )
  PROTECTED_OR_CANDIDATE_PATTERN = Regexp.new(
    '(?<![+\p{L}\p{N}])(?:\d{4}[ -]){3}\d{4}(?![\p{L}\p{N}])|' \
    '(?<![\p{L}\p{N}])(?:\+?\d{1,3}[ -])?\d{2,3}[ -]\d{3}[ -]\d{2}[ -]\d{2}(?![\p{L}\p{N}])|' \
    "(?<![+\\p{L}\\p{N}])(?<iin>#{IIN_DIGITS_FRAGMENT})(?![\\p{L}\\p{N}])"
  )

  # Whether the account identifies its patients by an IIN: its contact attributes hold one.
  def in_use?(account) = account.present? && account.custom_attribute_definitions.contact_attribute.exists?(attribute_key: ATTRIBUTE_KEY)
  def iin_like?(value) = normalize(value).to_s.length == 12
  def normalize(value) = value.to_s.gsub(/\D/, '').presence
  def sensitive_attribute_key?(key) = key.to_s.strip.match?(SENSITIVE_ATTRIBUTE_KEY_PATTERN)

  def valid?(value)
    iin = normalize(value)
    return false unless iin&.match?(/\A\d{12}\z/)

    digits = iin.chars.map(&:to_i)
    checksum = weighted_checksum(digits, FIRST_WEIGHTS)
    checksum = weighted_checksum(digits, SECOND_WEIGHTS) if checksum == 10
    (checksum == 10 ? 0 : checksum) == digits.last
  end

  # True for a valid 12-digit Kazakhstan personal IIN (YYMMDD + 20th/21st century digit 3..6 + valid check digit).
  def personal_iin?(value)
    iin = normalize(value)
    return false unless valid?(iin) && (century = CENTURY_BY_SEVENTH_DIGIT[iin[6].to_i])

    year = century + iin[0, 2].to_i
    month = iin[2, 2].to_i
    day = iin[4, 2].to_i
    Date.valid_date?(year, month, day) && Date.new(year, month, day) <= (Time.zone&.today || Time.current.to_date) + 1
  end

  def redact_text(text)
    transform_iin_text(text, tokenize: false)
  end

  def tokenize_or_redact_text(text)
    vault_active = defined?(Llm::IinTokenVault) && Llm::IinTokenVault.active?
    transform_iin_text(text, tokenize: vault_active)
  end

  def redact_customer_text(text)
    return text unless text.is_a?(String)

    unmasked = defined?(Llm::PiiSessionPseudonymizer) ? Llm::PiiSessionPseudonymizer.unmask_customer_text(text) : text
    stripped = defined?(Llm::IinTokenVault) ? Llm::IinTokenVault.strip_tokens(unmasked, REDACTED_PLACEHOLDER) : unmasked
    redact_text(stripped)
  end

  def redact_customer_payload(value)
    case value
    when String then redact_customer_text(value)
    when Array then value.map { |item| redact_customer_payload(item) }
    when Hash then value.transform_values { |item| redact_customer_payload(item) }
    else value
    end
  end

  def sanitize_identifier(value)
    return nil if value.nil?

    text = value.to_s
    text.strip.match?(/\A[\d -]+\z/) && iin_like?(text) ? nil : redact_text(text)
  end

  def tokenize_or_sanitize_identifier(value)
    return nil if value.nil?

    text = value.to_s
    if text.strip.match?(/\A[\d -]+\z/) && iin_like?(text)
      return defined?(Llm::IinTokenVault) && Llm::IinTokenVault.active? ? Llm::IinTokenVault.tokenize(text) : nil
    end

    tokenize_or_redact_text(text)
  end

  def sanitize_custom_attributes(attributes)
    return attributes unless attributes.is_a?(Hash)

    attributes.each_with_object({}) do |(key, val), result|
      result[key] = sanitize_value(val, tokenize: false) unless sensitive_attribute_key?(key)
    end
  end

  def tokenize_or_sanitize_custom_attributes(attributes)
    return attributes unless attributes.is_a?(Hash)
    return sanitize_custom_attributes(attributes) unless defined?(Llm::IinTokenVault) && Llm::IinTokenVault.active?

    attributes.each_with_object({}) do |(key, val), result|
      if sensitive_attribute_key?(key)
        result[key] = Llm::IinTokenVault.tokenize(val) if iin_like?(val)
      else
        result[key] = sanitize_value(val, tokenize: true)
      end
    end
  end

  def validate!(value)
    normalized = normalize(value)
    return value.to_s.strip.presence unless iin_like?(value)
    return normalized if valid?(normalized)

    raise Scheduling::Error.new(code: 'INVALID_IIN', message: 'Invalid IIN', status: :unprocessable_content)
  end

  def require_valid!(value)
    return if value.to_s.strip.empty?

    normalized = normalize(value)
    return normalized if valid?(normalized)

    raise Scheduling::Error.new(code: 'INVALID_IIN', message: INVALID_IIN_MESSAGE, status: :unprocessable_content)
  end

  def require_valid_in!(identifier: nil, custom_attributes: nil)
    attributes = custom_attributes.is_a?(String) ? parsed_attributes(custom_attributes) : custom_attributes.to_h
    require_valid!(attributes.with_indifferent_access[:iin])
    require_valid!(identifier)
  end

  def transform_iin_text(text, tokenize:)
    return text if !text.is_a?(String) || text.match?(DATA_URI_BASE64_PREFIX)

    safe = text.valid_encoding? ? text : text.scrub
    return text if safe.count('0-9') < 12

    redacted = apply_iin_redactions(safe, tokenize: tokenize)
    redacted == safe ? text : redacted
  end

  def apply_iin_redactions(safe, tokenize: false)
    labeled = safe.gsub(LABELED_IIN_PATTERN) do
      prefix = Regexp.last_match(1)
      digits = Regexp.last_match(2)
      replacement = tokenize ? Llm::IinTokenVault.tokenize(digits) : REDACTED_PLACEHOLDER
      "#{prefix}#{replacement}"
    end
    result = labeled.gsub(PROTECTED_OR_CANDIDATE_PATTERN) do |match|
      candidate = Regexp.last_match[:iin]
      if candidate && personal_iin?(candidate)
        tokenize ? Llm::IinTokenVault.tokenize(candidate) : REDACTED_PLACEHOLDER
      else
        match
      end
    end
    tokenize && defined?(Llm::IinTokenVault) ? Llm::IinTokenVault.retokenize_known_digits(result) : result
  end

  def sanitize_value(val, tokenize: false)
    case val
    when String then tokenize ? tokenize_or_redact_text(val) : redact_text(val)
    when Hash then tokenize ? tokenize_or_sanitize_custom_attributes(val) : sanitize_custom_attributes(val)
    when Array then val.map { |item| sanitize_value(item, tokenize: tokenize) }
    else val
    end
  end

  def parsed_attributes(text)
    parsed = JSON.parse(text)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def weighted_checksum(digits, weights) = weights.each_with_index.sum { |weight, index| digits[index] * weight } % 11
  private_class_method :transform_iin_text, :apply_iin_redactions, :weighted_checksum, :parsed_attributes, :sanitize_value
end
# rubocop:enable Metrics/ModuleLength
