module Scheduling::IinValidator
  module_function

  FIRST_WEIGHTS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].freeze
  SECOND_WEIGHTS = [3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2].freeze

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

  def weighted_checksum(digits, weights)
    weights.each_with_index.sum { |weight, index| digits[index] * weight } % 11
  end
  private_class_method :weighted_checksum
end
