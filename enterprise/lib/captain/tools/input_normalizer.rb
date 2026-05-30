module Captain::Tools::InputNormalizer
  module_function

  def optional_positive_id(value)
    numeric = integer_value(unwrap_id_envelope(value))
    return nil if numeric.nil? || numeric <= 0

    numeric
  end

  def required_positive_id(value, field_name:)
    numeric = integer_value(unwrap_id_envelope(value, field_name: field_name))
    return numeric if numeric.present? && numeric.positive?

    raise ArgumentError, "#{field_name} is required"
  end

  def integer_value(value)
    return nil if value.nil?
    return value if value.is_a?(Integer)
    return integer_from_float(value) if value.is_a?(Float)

    integer_from_string(value)
  end

  def unwrap_id_envelope(value, field_name: nil)
    parameters = envelope_parameters(value)
    return value if parameters.blank?
    return envelope_field_value(parameters, value, field_name) if field_name.present?

    envelope_id_value(parameters) || value
  rescue StandardError
    value
  end

  def envelope_parameters(value)
    return unless value.respond_to?(:to_h) && !value.is_a?(String)

    parameters = value.to_h.with_indifferent_access[:parameters]
    return unless parameters.is_a?(Hash)

    parameters.with_indifferent_access
  end

  def envelope_field_value(parameters, fallback, field_name)
    parameters.key?(field_name) ? parameters[field_name] : fallback
  end

  def envelope_id_value(parameters)
    id_key = parameters.keys.find { |key| key.to_s == 'id' || key.to_s.end_with?('_id') }
    parameters[id_key] if id_key.present?
  end

  def integer_from_float(value)
    return nil unless value.finite? && value == value.to_i

    value.to_i
  end

  def integer_from_string(value)
    text = value.to_s.strip
    return nil if text.blank? || !text.match?(/\A[+-]?\d+\z/)

    text.to_i
  end

  private_class_method :integer_value, :unwrap_id_envelope, :envelope_parameters, :envelope_field_value, :envelope_id_value,
                       :integer_from_float, :integer_from_string
end
