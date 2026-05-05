# frozen_string_literal: true

class Reminders::BooleanParam
  TRUE_VALUES = [true, 1, '1', 'true'].freeze
  FALSE_VALUES = [false, 0, '0', 'false'].freeze

  def self.call(value, default: nil, field_name: 'boolean')
    return default if value.nil?
    return true if truthy_value?(value)
    return false if falsey_value?(value)

    raise ArgumentError, "#{field_name} must be true or false"
  end

  def self.truthy?(value)
    call(value, default: false)
  rescue ArgumentError
    false
  end

  def self.truthy_value?(value)
    normalized_value(value).in?(TRUE_VALUES)
  end
  private_class_method :truthy_value?

  def self.falsey_value?(value)
    normalized_value(value).in?(FALSE_VALUES)
  end
  private_class_method :falsey_value?

  def self.normalized_value(value)
    return value.strip.downcase if value.is_a?(String)

    value
  end
  private_class_method :normalized_value
end
