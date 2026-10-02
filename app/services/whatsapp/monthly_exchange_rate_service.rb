require 'date'

class Whatsapp::MonthlyExchangeRateService
  FETCH_LOCK_DURATION = 1.minute
  RETRY_INTERVAL = 5.minutes

  def initialize(month:, clock: -> { Time.current })
    @month_start = normalize_month(month)
    @requested_date = @month_start
    @clock = clock
  end

  def perform
    record = find_or_create_record
    claim = claim_fetch(record)
    return claim if claim.is_a?(WhatsappUsageExchangeRate)
    return unless claim

    rate_data = fetch_rate_data
    mark_fetched(record, rate_data)
  rescue Whatsapp::MonthlyExchangeRateSource::RateUnavailable => e
    mark_unavailable(record, e.error_code) if record
    nil
  end

  private

  def normalize_month(value)
    date = if value.is_a?(DateTime)
             value.to_time.utc.to_date
           elsif value.is_a?(Time) || (value.respond_to?(:utc) && value.respond_to?(:to_date))
             value.utc.to_date
           elsif value.is_a?(Date)
             value
           else
             Date.iso8601(value.to_s)
           end
    Date.new(date.year, date.month, 1)
  rescue ArgumentError
    raise ArgumentError, 'month must be a date or time value'
  end

  def find_or_create_record
    WhatsappUsageExchangeRate.create_or_find_by!(month_start: @month_start) do |record|
      record.requested_date = @requested_date
      record.status = 'unavailable'
    end
  end

  def claim_fetch(record)
    result = record.with_lock { reserve_fetch(record) }
    return record if result == :fetched
    return true if result == :claimed
  end

  def reserve_fetch(record)
    return :fetched if record.fetched?
    return :waiting if retry_pending?(record)

    record.update!(
      requested_date: @requested_date,
      status: 'fetching',
      source_url: source_url,
      retry_after: now + FETCH_LOCK_DURATION,
      error_code: nil
    )
    :claimed
  end

  def retry_pending?(record)
    record.retry_after.present? && record.retry_after > now
  end

  def fetch_rate_data
    Whatsapp::MonthlyExchangeRateSource.new(requested_date: @requested_date).fetch
  end

  def source_url
    Whatsapp::MonthlyExchangeRateSource.new(requested_date: @requested_date).source_url
  end

  def mark_fetched(record, rate_data)
    record.with_lock do
      record.update!(fetched_attributes(rate_data)) unless record.fetched?
    end
    record
  end

  def fetched_attributes(rate_data)
    rate_data.slice(:effective_date, :nominal_rate, :nominal_units, :rate_per_usd).merge(
      status: 'fetched',
      source_url: source_url,
      fetched_at: now,
      retry_after: nil,
      error_code: nil
    )
  end

  def mark_unavailable(record, error_code)
    record.with_lock do
      record.update!(unavailable_attributes(error_code)) unless record.fetched?
    end
  end

  def unavailable_attributes(error_code)
    {
      effective_date: nil,
      nominal_rate: nil,
      nominal_units: nil,
      rate_per_usd: nil,
      status: 'unavailable',
      source_url: source_url,
      fetched_at: nil,
      retry_after: now + RETRY_INTERVAL,
      error_code: error_code
    }
  end

  def now
    @clock.call.utc
  end
end
