require 'bigdecimal'

module Crm::AmountFormatter
  module_function

  def major_from_minor(amount_minor)
    return if amount_minor.blank?

    format_major(BigDecimal(amount_minor.to_s) / 100)
  end

  WHOLE_MAJOR_AMOUNT = /\A[+-]?\d+(?:[\.,]0+)?\z/

  def minor_from_major(amount)
    return if amount.blank?

    value = normalize_major_amount(amount)
    (BigDecimal(value) * 100).to_i
  rescue ArgumentError
    raise ArgumentError, 'amount must be a whole number in major units'
  end

  def format_major(amount)
    amount.to_s('F')
          .sub(/(\.\d*?)0+\z/, '\\1')
          .sub(/\.\z/, '')
  end

  def normalize_major_amount(amount)
    value = amount.to_s.strip.delete(' ')
    raise ArgumentError unless value.match?(WHOLE_MAJOR_AMOUNT)

    value.tr(',', '.')
  end
end
