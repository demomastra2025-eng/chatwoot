module Scheduling::IntegerNumericNormalizer
  INTEGER_NUMERIC_STRING = /\A[+-]?\d+(?:\.0+)?\z/

  module_function

  def normalize(value, field_name: 'value')
    normalized = normalize_value(value)
    return normalized unless normalized.nil?

    raise ArgumentError, "#{field_name} must be an integer"
  end

  def normalize_or_zero(value, field_name: 'value')
    return 0 if value.blank?

    normalize(value, field_name: field_name)
  end

  def normalize_value(value)
    case value
    when Integer
      value
    when Float, BigDecimal
      return nil unless value.finite? && value == value.to_i

      value.to_i
    else
      normalize_string(value)
    end
  end

  def normalize_string(value)
    text = value.to_s.strip
    return nil if text.blank? || !text.match?(INTEGER_NUMERIC_STRING)

    text.to_i
  end
end
