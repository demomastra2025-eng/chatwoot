# frozen_string_literal: true

# How the super admin shows times, sizes and numbers to a person.
#
# * Times are Astana time (UTC+5, Kazakhstan has had a single zone since 2024-03-01), never UTC. The offset is fixed
#   instead of a zone name, so the screen does not depend on how fresh the tzdata of the server is.
# * Sizes use Russian units (Б, КБ, МБ, ГБ, ТБ), 1 КБ = 1024 Б like the quotas.
# * Numbers have a space between thousands and a comma before decimals; dollar amounts have two decimals.
module SuperAdmin::DisplayHelper
  DATETIME_FORMAT = '%d.%m.%Y %H:%M'
  DATE_FORMAT = '%d.%m.%Y'
  # The value of an `<input type="datetime-local">`
  INPUT_FORMAT = '%Y-%m-%dT%H:%M:%S'
  BYTE_UNITS = %w[Б КБ МБ ГБ ТБ].freeze
  NUMBER_OPTIONS = { delimiter: ' ', separator: ',' }.freeze

  class << self
    # The moment as Time with the Astana offset; nil for a blank or unreadable value.
    def in_astana(time)
      moment = time.is_a?(String) ? parse(time) : time
      moment.to_time.getlocal(Accounts::Plans::ASTANA_OFFSET) if moment.respond_to?(:to_time)
    end

    def format_time(time, format = DATETIME_FORMAT)
      in_astana(time)&.strftime(format)
    end

    # A calendar date (the date of a contract: no time of day, no zone) as it is stored: "15.10.2026". It is never
    # moved to another day by a zone; nil for a blank date.
    def format_calendar_date(date)
      date&.strftime(DATE_FORMAT)
    end

    # A value typed into a datetime-local input is Astana wall-clock time; anything that names its own zone or
    # offset is left to the normal parsing.
    def parse_input(value)
      return value unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?\z/)

      Time.zone.parse("#{value} #{Accounts::Plans::ASTANA_OFFSET}") || value
    end

    def format_bytes(bytes)
      return if bytes.nil?

      value = bytes.to_f
      unit = 0
      while value >= 1024 && unit < BYTE_UNITS.size - 1
        value /= 1024
        unit += 1
      end
      precision = unit.zero? || value >= 100 ? 0 : 1
      number = ActiveSupport::NumberHelper.number_to_rounded(value, precision: precision, strip_insignificant_zeros: true, **NUMBER_OPTIONS)
      "#{number} #{BYTE_UNITS[unit]}"
    end

    def format_number(number)
      return if number.nil?

      ActiveSupport::NumberHelper.number_to_delimited(number, **NUMBER_OPTIONS)
    end

    # An amount in US dollars (the AI models are paid in dollars): "$1 234,50"
    def format_usd(amount)
      return if amount.nil?

      "$#{ActiveSupport::NumberHelper.number_to_rounded(amount, precision: 2, **NUMBER_OPTIONS)}"
    end

    private

    def parse(text)
      Time.zone.parse(text)
    rescue ArgumentError
      nil
    end
  end

  # "15.10.2026 22:15" in Astana time; nil for a blank time
  def super_admin_time(time, format = DATETIME_FORMAT)
    SuperAdmin::DisplayHelper.format_time(time, format)
  end

  # "15.10.2026"
  def super_admin_date(time)
    SuperAdmin::DisplayHelper.format_time(time, DATE_FORMAT)
  end

  # "15.10.2026" for a date without a time of day (the date of a contract)
  def super_admin_calendar_date(date)
    SuperAdmin::DisplayHelper.format_calendar_date(date)
  end

  # The value of a datetime-local input, in Astana time
  def super_admin_input_time(time)
    SuperAdmin::DisplayHelper.format_time(time, INPUT_FORMAT)
  end

  # "36 ГБ", "512 МБ"
  def super_admin_bytes(bytes)
    SuperAdmin::DisplayHelper.format_bytes(bytes)
  end

  # "12 450"
  def super_admin_number(number)
    SuperAdmin::DisplayHelper.format_number(number)
  end

  # "$1 234,50"
  def super_admin_usd(amount)
    SuperAdmin::DisplayHelper.format_usd(amount)
  end
end
