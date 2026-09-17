class AutomationRules::AppointmentDerivedConditionService
  FIELD_KEYS = %w[starts_at_weekday starts_at_time service_id].freeze

  def initialize(rule, appointment)
    @rule = rule
    @appointment = appointment
  end

  def evaluate(key, operator, condition)
    case key
    when 'starts_at_weekday'
      evaluate_weekday(condition, operator)
    when 'starts_at_time'
      evaluate_time(condition, operator)
    when 'service_id'
      evaluate_service(condition, operator)
    else
      false
    end
  end

  def supports?(key)
    key.to_s.in?(FIELD_KEYS)
  end

  private

  attr_reader :appointment, :rule

  def evaluate_service(condition, operator)
    expected_ids = normalize_values(condition['values'])
    return false if expected_ids.blank?

    stored_ids = appointment.custom_attributes.to_h['service_ids']
    appointment_ids = Array.wrap(stored_ids.presence || appointment.service_id).filter_map do |value|
      AutomationRules::AppointmentFieldCatalog.normalize_service_id(value)&.to_s
    end
    intersects = appointment_ids.intersect?(expected_ids)
    contains_only = appointment_ids.present? && (appointment_ids - expected_ids).empty?

    {
      'equal_to' => intersects,
      'not_equal_to' => !intersects,
      'contains_only' => contains_only,
      'not_contains_only' => !contains_only
    }.fetch(operator, false)
  end

  def evaluate_time(condition, operator)
    candidate = local_starts_at
    return false if candidate.blank?

    expected_minutes = Array.wrap(condition['values']).filter_map { |value| normalize_time_of_day(value) }
    return false unless expected_minutes.one?

    candidate_minutes = (candidate.hour * 60) + candidate.min
    evaluate_comparable(candidate_minutes, expected_minutes.first, operator)
  end

  def evaluate_weekday(condition, operator)
    candidate = local_starts_at&.wday&.to_s
    expected_weekdays = normalize_values(condition['values'])
    return false if candidate.blank? || expected_weekdays.blank?

    operator == 'equal_to' ? expected_weekdays.include?(candidate) : expected_weekdays.exclude?(candidate)
  end

  def evaluate_comparable(candidate, expected, operator)
    return candidate == expected if operator == 'equal_to'
    return candidate != expected if operator == 'not_equal_to'
    return candidate > expected if operator == 'is_greater_than'
    return candidate < expected if operator == 'is_less_than'

    false
  end

  def local_starts_at
    timezone_name = rule.account.reporting_timezone.presence
    timezone = (ActiveSupport::TimeZone[timezone_name] if timezone_name) || Time.zone
    appointment.starts_at&.in_time_zone(timezone)
  end

  def normalize_time_of_day(value)
    return unless value.to_s.match?(AutomationRules::AppointmentFieldCatalog::TIME_OF_DAY_PATTERN)

    hours, minutes = value.to_s.split(':').map(&:to_i)
    (hours * 60) + minutes
  end

  def normalize_values(values)
    Array.wrap(values).filter_map { |value| value.to_s.strip.presence }
  end
end
