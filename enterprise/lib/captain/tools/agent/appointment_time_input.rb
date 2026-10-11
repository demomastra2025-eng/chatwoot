# frozen_string_literal: true

module Captain::Tools::Agent::AppointmentTimeInput
  LOCAL_FORMAT = /\A(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?\z/
  OFFSET_FORMAT = /(?:Z|[+-]\d{2}:?\d{2})\z/

  module_function

  def timezone(resource_timezone:, account_timezone: nil)
    (ActiveSupport::TimeZone[resource_timezone] if resource_timezone.present?) ||
      (ActiveSupport::TimeZone[account_timezone] if account_timezone.present?) || Time.zone
  end

  # Calendar clocks are resolved here, not by model arithmetic. An explicit
  # offset copied from a slot remains an absolute instant for compatibility.
  def parse(value, timezone:, field_name:)
    text = value.to_s.strip
    if text.match?(OFFSET_FORMAT)
      instant = Scheduling::InputValidation.datetime(text, field_name: field_name)
      return text.end_with?('Z') ? instant.utc : instant.getlocal(Date._parse(text, false).fetch(:offset))
    end

    parts = LOCAL_FORMAT.match(text)&.captures&.map { |part| part&.to_i }
    raise ArgumentError unless parts

    year, month, day, hour, minute, second = parts
    second ||= 0
    raise ArgumentError unless Date.valid_date?(year, month, day) && (0..23).cover?(hour) && (0..59).cover?(minute) && (0..59).cover?(second)

    clock = Time.utc(year, month, day, hour, minute, second)
    periods = timezone.tzinfo.periods_for_local(clock)
    raise ArgumentError unless periods.one?

    (clock - periods.first.observed_utc_offset).in_time_zone(timezone)
  rescue Scheduling::Error => e
    raise Scheduling::Error.new(code: e.code, message: e.message, status: e.status,
                                details: e.details.to_h.merge(mutation_executed: false))
  rescue ArgumentError, TypeError
    raise Scheduling::Error.new(
      code: 'INVALID_DATE', status: :unprocessable_content,
      message: "#{field_name} must be an unambiguous local calendar datetime or an exact ISO 8601 slot datetime",
      details: { field: field_name, reason: 'invalid_or_ambiguous_local_datetime', mutation_executed: false }
    )
  end
end
