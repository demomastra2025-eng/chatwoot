module Scheduling::InputValidation
  # The offset is range-checked: Time.zone.parse drops an impossible one (+25:00, +05:99) and reads the instant as UTC.
  DATETIME_FORMAT = /\A\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z| ?[+-](?:[01]\d|2[0-3]):?[0-5]\d)?)?\z/
  DATE_FORMAT = /\A(\d{4})-(\d{2})-(\d{2})\z/

  module_function

  # An existing calendar date written exactly as YYYY-MM-DD, or nil. Date.iso8601 would complete '2031-10' to 1 October,
  # read '31-10-14' as 2031-10-14 and '60-05-01' as 2060-05-01.
  def parse_date(value)
    match = DATE_FORMAT.match(value.to_s.strip)
    return unless match

    year, month, day = match.captures.map(&:to_i)
    Date.new(year, month, day) if Date.valid_date?(year, month, day)
  end

  def date(value, field_name:)
    parsed = parse_date(value)
    return parsed if parsed

    raise Scheduling::Error.new(code: 'INVALID_DATE', message: "#{field_name} must be an existing calendar date in YYYY-MM-DD format",
                                status: :unprocessable_content, details: { field: field_name, reason: 'invalid_date' })
  end

  def datetime(value, field_name:)
    text = value.to_s.strip
    parts = Date._parse(text, false)
    valid = text.match?(DATETIME_FORMAT) && Date.valid_date?(parts[:year], parts[:mon], parts[:mday]) &&
            (0..23).cover?(parts.fetch(:hour, 0)) && (0..59).cover?(parts.fetch(:min, 0)) &&
            (0..59).cover?(parts.fetch(:sec, 0))
    raise ArgumentError unless valid

    Time.zone.parse(text) || raise(ArgumentError)
  rescue ArgumentError, TypeError
    raise Scheduling::Error.new(code: 'INVALID_DATE', message: "#{field_name} must be a valid date or ISO 8601 datetime",
                                status: :unprocessable_content, details: { field: field_name, reason: 'invalid_date' })
  end

  def interval!(starts_at:, ends_at:)
    return if ends_at > starts_at

    raise Scheduling::Error.new(code: 'INVALID_DATE_RANGE', message: 'ends_at must be greater than starts_at',
                                status: :unprocessable_content, details: { reason: 'invalid_date_range' })
  end

  def service!(account:, value:)
    return if value.blank?

    id = Scheduling::IntegerNumericNormalizer.normalize(value, field_name: 'service_id')
    record = account.scheduling_services.active.find_by(id: id)
    return record if record

    raise Scheduling::Error.new(code: 'UNKNOWN_SERVICE', message: 'Unknown service_id for this account; use an ID returned by the service catalog',
                                status: :not_found, details: { field: 'service_id', reason: 'unknown_service' })
  rescue ArgumentError, TypeError
    raise Scheduling::Error.new(code: 'INVALID_SERVICE_ID', message: 'service_id must be an integer ID returned by the service catalog',
                                status: :unprocessable_content, details: { field: 'service_id', reason: 'invalid_service_id' })
  end
end
