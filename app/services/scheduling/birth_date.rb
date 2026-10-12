# frozen_string_literal: true

# A patient birth date is an existing calendar date written as YYYY-MM-DD. The generic dashboard date attribute widget
# sends the same date with an ISO 8601 time part (1990-03-05T00:00:00.000Z), which is accepted for custom attributes; the
# time of day and the UTC offset are range-checked, and a space instead of the T is refused, because the readers of a
# stored card (Date.iso8601 when the card is copied into an appointment, the dashboard) do not understand it. Parsers
# that build a Time (Time.zone.parse, the ActiveRecord date-time cast) roll 30 February over to 2 March and the
# ActiveRecord date cast turns it into nil, so the calendar check is made explicitly, before anything is stored.
module Scheduling::BirthDate
  FIELD = 'birth_date'
  DATE = /(\d{4})-(\d{2})-(\d{2})/
  TIME = /T(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d+)?)?(?:Z|[+-](?:[01]\d|2[0-3])(?::?[0-5]\d)?)?/
  PLAIN_FORMAT = /\A#{DATE}\z/
  FORMAT = /\A#{DATE}(?:#{TIME})?\z/
  # The calendar date a text starts with, in the ISO form (1990-02-30, 1990-02-30T00:00:00Z) or the DD.MM.YYYY form the
  # dashboard also reads on cards that already carry it.
  ISO_PREFIX = /\A#{DATE}(?!\d)/
  DOTTED_PREFIX = /\A(\d{2})\.(\d{2})\.(\d{4})(?!\d)/

  module_function

  # plain: true accepts only YYYY-MM-DD (the documented format of the birth_date parameter).
  def valid?(value, plain: false)
    match = (plain ? PLAIN_FORMAT : FORMAT).match(value.to_s)
    match.present? && Date.valid_date?(match[1].to_i, match[2].to_i, match[3].to_i)
  end

  # An absent or empty value leaves or clears the field and passes. Returns the value so a caller can assign it.
  def validate!(value, field: FIELD, plain: false)
    return value if value.nil? || value == '' || valid?(value, plain: plain)

    raise Scheduling::Error.new(
      code: 'INVALID_BIRTH_DATE', message: "#{field} must be an existing calendar date in YYYY-MM-DD format",
      status: :unprocessable_content, details: { field: field, reason: 'invalid_birth_date' }
    )
  end

  # Checks the birth_date entry of a custom attributes payload (Hash or permitted Parameters); other keys are not inspected.
  # A value equal to the one the card already holds is left alone, so a legacy card stays editable.
  def validate_attributes!(attributes, field: "custom_attributes.#{FIELD}", current: nil)
    return attributes unless attributes.respond_to?(:key?)

    key = [FIELD, FIELD.to_sym].find { |name| attributes.key?(name) }
    return attributes unless key
    return attributes if current.respond_to?(:key?) && current[FIELD].present? && current[FIELD] == attributes[key]

    validate!(attributes[key], field: field)
    attributes
  end

  # True only for a value that is written as a calendar date but names a day that does not exist (1990-02-30, 30.02.1990,
  # 1990-13-40T00:00:00Z). Text that is not a date at all ('5/3/1990', '5 March 1990') is not judged here: untrusted writers
  # (widget visitor, public API client, CSV import) have always been free to keep such free text in the attribute.
  def nonexistent_date?(value)
    text = value.to_s.strip
    if (match = ISO_PREFIX.match(text))
      !Date.valid_date?(match[1].to_i, match[2].to_i, match[3].to_i)
    elsif (match = DOTTED_PREFIX.match(text))
      !Date.valid_date?(match[3].to_i, match[2].to_i, match[1].to_i)
    else
      false
    end
  end

  # The calendar date of a valid value ('1990-03-05T00:00:00.000Z' becomes '1990-03-05'); any other value is returned as it
  # is, so the reader that needs a plain date reports it.
  def normalize(value)
    valid?(value) ? value.to_s[0, 10] : value
  end
end
