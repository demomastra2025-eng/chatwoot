class Crm::FieldRequirementValidator
  def initialize(validation:, value:)
    @validation = validation.to_h.stringify_keys
    @value = value
  end

  def issue
    length_issue || numeric_issue || pattern_issue
  end

  private

  attr_reader :validation, :value

  def length_issue
    length = value.to_s.length
    return 'min_length' if validation['min_length'].present? && length < validation['min_length'].to_i
    return 'max_length' if validation['max_length'].present? && length > validation['max_length'].to_i
  end

  def numeric_issue
    return unless validation['minimum'].present? || validation['maximum'].present?

    numeric = Float(value)
    minimum_issue(numeric) || maximum_issue(numeric)
  rescue ArgumentError, TypeError
    'number'
  end

  def minimum_issue(numeric)
    'minimum' if validation['minimum'].present? && numeric < validation['minimum'].to_f
  end

  def maximum_issue(numeric)
    'maximum' if validation['maximum'].present? && numeric > validation['maximum'].to_f
  end

  def pattern_issue
    return if validation['pattern'].blank?
    return if Regexp.new(validation['pattern']).match?(value.to_s)

    'pattern'
  rescue RegexpError
    'pattern'
  end
end
