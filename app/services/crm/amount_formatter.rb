require 'bigdecimal'

module Crm::AmountFormatter
  module_function

  def major_from_minor(amount_minor)
    return if amount_minor.blank?

    format_major(BigDecimal(amount_minor.to_s) / 100)
  end

  def minor_from_major(amount)
    return if amount.blank?

    (parse_major(amount) * 100).round(0).to_i
  rescue ArgumentError
    raise ArgumentError, 'amount must be a valid number'
  end

  def format_major(amount)
    amount.to_s('F')
          .sub(/(\.\d*?)0+\z/, '\\1')
          .sub(/\.\z/, '')
  end

  def parse_major(amount)
    value = amount.to_s.strip.delete(' ')
    value = value.tr(',', '.') if value.exclude?('.') && value.count(',') == 1

    BigDecimal(value)
  end
end
