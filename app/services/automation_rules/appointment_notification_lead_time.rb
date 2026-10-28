class AutomationRules::AppointmentNotificationLeadTime
  MINUTES = 60

  def self.short?(appointment, rule: nil, now: Time.current)
    return false unless appointment.starts_at && appointment.created_at
    return false if explicit_smaller_condition?(rule)

    appointment.starts_at - appointment.created_at < MINUTES.minutes || appointment.starts_at - now < MINUTES.minutes
  end

  def self.explicit_smaller_condition?(rule)
    Array(rule&.conditions).any? do |condition|
      condition = condition.to_h.with_indifferent_access
      next false unless condition[:attribute_key] == 'lead_time_minutes'
      next false unless condition[:filter_operator].in?(%w[equal_to less_than greater_than is_less_than is_greater_than])

      Array.wrap(condition[:values]).any? { |value| value.to_i < MINUTES }
    end
  end
end
