# frozen_string_literal: true

class Scheduling::IdListParamParser
  ERROR_MESSAGE = 'must contain positive integer IDs'

  def self.parse(value, field_name:)
    new(value: value, field_name: field_name).parse
  end

  def initialize(value:, field_name:)
    @value = value
    @field_name = field_name
  end

  def parse
    raw_values.filter_map do |item|
      text = item.to_s.strip
      next if text.blank?

      id = Integer(text, 10)
      raise ArgumentError unless id.positive?

      id
    end.uniq
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{field_name} #{ERROR_MESSAGE}"
  end

  private

  attr_reader :value, :field_name

  def raw_values
    return [] if value.nil?
    return value.split(',') if value.is_a?(String)
    return value if valid_array?

    raise ArgumentError
  end

  def valid_array?
    value.is_a?(Array) && value.all? { |item| item.is_a?(String) || item.is_a?(Integer) }
  end
end
