class AutomationRules::AppointmentConditionService
  def initialize(rule, appointment, options = {})
    @rule = rule
    @appointment = appointment
    @changed_attributes = options[:changed_attributes]
  end

  def perform
    groups = grouped_condition_results
    return false if groups.blank?

    groups.any?(&:all?)
  end

  private

  attr_reader :rule, :appointment, :changed_attributes

  def evaluate_condition(condition)
    key = condition['attribute_key'].to_s
    operator = condition['filter_operator'].to_s
    return false unless field_catalog.operator_supported?(key, operator)

    return evaluate_standard_condition(key, operator, condition) if field_catalog.standard_field?(key)

    definition = field_catalog.custom_definition_for(key)
    return false if definition.blank?

    evaluate_custom_condition(definition, operator, condition)
  end

  def evaluate_custom_condition(definition, operator, condition)
    raw_value = appointment.custom_attributes&.[](definition.key)
    return value_present?(raw_value) if operator == 'is_present'
    return !value_present?(raw_value) if operator == 'is_not_present'

    case definition.field_type
    when *AutomationRules::AppointmentFieldCatalog::DISCRETE_FIELD_TYPES
      evaluate_discrete_condition(definition.field_type, raw_value, condition, operator)
    when *AutomationRules::AppointmentFieldCatalog::TEXT_FIELD_TYPES
      evaluate_text_condition(raw_value, condition, operator)
    when *AutomationRules::AppointmentFieldCatalog::NUMERIC_FIELD_TYPES
      evaluate_numeric_condition(raw_value, condition, operator)
    when 'date'
      evaluate_date_condition(raw_value, condition, operator)
    when 'datetime'
      evaluate_datetime_condition(raw_value, condition, operator)
    else
      false
    end
  end

  def evaluate_date_condition(raw_value, condition, operator)
    candidate = normalize_date(raw_value)
    return false if candidate.nil?

    values = normalize_date_values(condition)
    return false if values.blank?

    evaluate_comparable_condition(candidate, values, operator)
  end

  def evaluate_datetime_condition(raw_value, condition, operator)
    candidate = normalize_datetime(raw_value)
    return false if candidate.nil?

    values = normalize_datetime_values(condition)
    return false if values.blank?

    evaluate_comparable_condition(candidate, values, operator)
  end

  def evaluate_discrete_condition(field_type, raw_value, condition, operator)
    values = normalize_discrete_values(field_type, condition['values'])
    return false if values.blank?

    case field_type
    when 'checkbox'
      candidate = normalize_boolean(raw_value)
      operator == 'equal_to' ? values.include?(candidate) : values.exclude?(candidate)
    when 'multiselect'
      candidate_values = Array.wrap(raw_value).filter_map { |value| text_value(value) }
      overlapping = candidate_values.intersect?(values)
      operator == 'equal_to' ? overlapping : !overlapping
    else
      candidate = text_value(raw_value)
      operator == 'equal_to' ? values.include?(candidate) : values.exclude?(candidate)
    end
  end

  def evaluate_numeric_condition(raw_value, condition, operator)
    candidate = normalize_number(raw_value)
    return false if candidate.nil?

    values = normalize_numeric_values(condition)
    return false if values.blank?

    evaluate_comparable_condition(candidate, values, operator)
  end

  def evaluate_standard_condition(key, operator, condition)
    return derived_condition_service.evaluate(key, operator, condition) if derived_condition_service.supports?(key)

    raw_value = appointment.public_send(key)

    case operator
    when 'equal_to'
      normalize_values(condition['values']).include?(raw_value.to_s)
    when 'not_equal_to'
      normalize_values(condition['values']).exclude?(raw_value.to_s)
    when 'contains'
      text_value(raw_value)&.downcase&.include?(first_value(condition)&.downcase.to_s) || false
    when 'does_not_contain'
      candidate = text_value(raw_value)
      candidate.present? && candidate.downcase.exclude?(first_value(condition)&.downcase.to_s)
    when 'starts_with'
      text_value(raw_value)&.downcase&.start_with?(first_value(condition)&.downcase.to_s) || false
    when 'is_present'
      value_present?(raw_value)
    when 'is_not_present'
      !value_present?(raw_value)
    else
      false
    end
  end

  def evaluate_text_condition(raw_value, condition, operator)
    candidate = text_value(raw_value)
    return false if candidate.blank? && operator != 'not_equal_to'

    values = normalize_values(condition['values'])
    case operator
    when 'equal_to'
      values.any? { |value| candidate.casecmp?(value) }
    when 'not_equal_to'
      candidate.blank? || values.none? { |value| candidate.casecmp?(value) }
    when 'contains'
      candidate.downcase.include?(first_value(condition)&.downcase.to_s)
    when 'does_not_contain'
      candidate.present? && candidate.downcase.exclude?(first_value(condition)&.downcase.to_s)
    when 'starts_with'
      candidate.downcase.start_with?(first_value(condition)&.downcase.to_s)
    else
      false
    end
  end

  def evaluate_comparable_condition(candidate, values, operator)
    return values.include?(candidate) if operator == 'equal_to'
    return values.exclude?(candidate) if operator == 'not_equal_to'
    return candidate > values.first if operator == 'is_greater_than'
    return candidate < values.first if operator == 'is_less_than'

    false
  end

  def field_catalog
    @field_catalog ||= AutomationRules::AppointmentFieldCatalog.new(account: rule.account)
  end

  def derived_condition_service
    @derived_condition_service ||= AutomationRules::AppointmentDerivedConditionService.new(rule, appointment)
  end

  def first_value(condition)
    normalize_values(condition['values']).first
  end

  def grouped_condition_results
    groups = [[]]

    rule.conditions.each do |condition|
      groups.last << evaluate_condition(condition)
      groups << [] if condition['query_operator'].to_s.casecmp('OR').zero?
    end

    groups.reject(&:blank?)
  end

  def normalize_boolean(value)
    case value
    when true, 'true', 1, '1'
      true
    when false, 'false', 0, '0'
      false
    end
  end

  def normalize_date(value)
    return if value.blank?

    value.is_a?(Date) ? value : Date.iso8601(value.to_s)
  rescue Date::Error
    nil
  end

  def normalize_date_values(condition)
    Array.wrap(condition['values']).filter_map { |value| normalize_date(value) }
  end

  def normalize_datetime(value)
    return if value.blank?

    value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone) ? value : Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def normalize_datetime_values(condition)
    Array.wrap(condition['values']).filter_map { |value| normalize_datetime(value) }
  end

  def normalize_discrete_values(field_type, values)
    Array.wrap(values).filter_map do |value|
      field_type == 'checkbox' ? normalize_boolean(value) : text_value(value)
    end
  end

  def normalize_number(value)
    return if value.blank?

    return value.to_f if value.is_a?(Numeric)

    Float(value)
  rescue ArgumentError, TypeError
    nil
  end

  def normalize_numeric_values(condition)
    Array.wrap(condition['values']).filter_map { |value| normalize_number(value) }
  end

  def normalize_values(values)
    Array.wrap(values).filter_map { |value| text_value(value) }
  end

  def text_value(value)
    value.to_s.strip.presence
  end

  def value_present?(value)
    return true if value == false

    value.present?
  end
end
