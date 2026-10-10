module Scheduling::InputValidation
  DATETIME_FORMAT = /\A\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z| ?[+-]\d{2}:?\d{2})?)?\z/

  module_function

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
