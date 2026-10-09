# frozen_string_literal: true

module Reports
  class DateRange
    DEFAULT_RANGE_DAYS = 30
    MAX_RANGE_DAYS = 90

    attr_reader :from_date, :to_date, :from_at, :until_at, :timezone

    def initialize(account:, params: {}, now: Time.current)
      @timezone = resolve_timezone(account)
      @from_date, @to_date = resolve_dates(params, now)
      validate_range!
      @from_at = local_midnight(from_date)
      @until_at = local_midnight(to_date + 1.day)
    end

    def meta
      {
        from_date: from_date.iso8601,
        to_date: to_date.iso8601,
        timezone: timezone.name,
        max_range_days: MAX_RANGE_DAYS
      }
    end

    private

    def resolve_timezone(account)
      timezone_name = account.reporting_timezone.presence || Time.zone&.name || 'UTC'
      ActiveSupport::TimeZone[timezone_name] || raise(ArgumentError, 'Invalid reporting timezone')
    end

    def resolve_dates(params, now)
      from_date = parse_date(params[:from_date], :from_date)
      to_date = parse_date(params[:to_date], :to_date)
      today = now.in_time_zone(timezone).to_date
      to_date ||= today
      from_date ||= to_date - (DEFAULT_RANGE_DAYS - 1).days
      [from_date, to_date]
    end

    def parse_date(value, field)
      return if value.nil? || value.to_s.blank?
      return Date.iso8601(value.to_s) if value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      raise ArgumentError, "#{field} must use YYYY-MM-DD"
    rescue Date::Error
      raise ArgumentError, "#{field} must be a valid date"
    end

    def validate_range!
      raise ArgumentError, 'from_date must be on or before to_date' if from_date > to_date
      return if (to_date - from_date).to_i + 1 <= MAX_RANGE_DAYS

      raise ArgumentError, "Report ranges cannot exceed #{MAX_RANGE_DAYS} days"
    end

    def local_midnight(date)
      timezone.local(date.year, date.month, date.day).utc
    end
  end
end
