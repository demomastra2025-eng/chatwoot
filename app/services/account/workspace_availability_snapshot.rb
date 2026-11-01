# frozen_string_literal: true

# Public availability is a projection of the same policy used by server-side
# replies. Clients only compare instants, rather than interpreting a second
# version of working hours, breaks, holidays and daylight-saving rules.
class Account::WorkspaceAvailabilitySnapshot
  DAYS_AHEAD = 14

  def initialize(account:, at: Time.current)
    @account = account
    @zone = ActiveSupport::TimeZone[account.workspace_working_hours_timezone]
    @date = at.in_time_zone(@zone).to_date
  end

  def as_json(*)
    Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
      {
        configured: @account.workspace_working_hours_configured?,
        timezone: @zone.tzinfo.name,
        valid_from: beginning_of(@date).iso8601,
        valid_until: beginning_of(@date + DAYS_AHEAD).iso8601,
        intervals: open_intervals.map { |start_at, end_at| { starts_at: start_at.iso8601, ends_at: end_at.iso8601 } }
      }
    end
  end

  private

  def cache_key
    ['workspace-availability-v1', @account.cache_key_with_version, @date.iso8601]
  end

  def open_intervals
    boundaries.each_cons(2).with_object([]) do |(start_at, end_at), result|
      next unless @account.workspace_open_at?(start_at)

      if result.last&.last == start_at
        result.last[1] = end_at
      else
        result << [start_at, end_at]
      end
    end
  end

  def boundaries
    first = beginning_of(@date)
    last = beginning_of(@date + DAYS_AHEAD)
    clocks = (0..DAYS_AHEAD).flat_map { |offset| daily_boundaries(@date + offset) }
    transitions = @zone.tzinfo.transitions_up_to(last.utc, first.utc).map { |transition| transition.at.to_time }
    (clocks + transitions + [first, last]).select { |time| time.between?(first, last) }.uniq.sort
  end

  def daily_boundaries(date)
    schedule = @account.workspace_working_hours_schedule.find { |day| day['day_of_week'].to_i == date.wday }.to_h
    minutes = [0, schedule_minute(schedule, 'open'), schedule_minute(schedule, 'close')]
    @account.workspace_break_schedule.each do |entry|
      next unless entry['days'].include?(date.wday)

      minutes.push(clock_minute(entry['start_time']), clock_minute(entry['end_time']))
    end
    minutes.uniq.flat_map { |minute| local_instants(date, minute) }
  end

  def local_instants(date, minute)
    local = Time.utc(date.year, date.month, date.day) + minute.minutes
    # A repeated local clock has two instants; a skipped clock has none. Include
    # the zone transitions separately so both sides retain the policy's meaning.
    @zone.tzinfo.periods_for_local(local).map { |period| (local - period.utc_total_offset).utc }
  end

  def beginning_of(date)
    @zone.local(date.year, date.month, date.day).utc
  end

  def schedule_minute(schedule, prefix)
    (schedule["#{prefix}_hour"].to_i * 60) + schedule["#{prefix}_minutes"].to_i
  end

  def clock_minute(clock)
    hour, minute = clock.split(':').map(&:to_i)
    (hour * 60) + minute
  end
end
