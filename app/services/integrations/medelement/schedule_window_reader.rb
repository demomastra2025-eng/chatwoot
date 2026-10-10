class Integrations::Medelement::ScheduleWindowReader
  def initialize(payload:, starts_on:, ends_on:, time_zone:)
    @payload = payload
    @dates = starts_on..ends_on
    @time_zone = time_zone
  end

  def perform
    @dates.flat_map { |date| windows_for_date(date) }.sort_by(&:first)
  end

  private

  def windows_for_date(date)
    invalid! unless @payload.is_a?(Hash)
    day = @payload[date.strftime('%d.%m.%Y')]
    invalid! unless day.is_a?(Hash) && day['timetable'].is_a?(Array)
    rows = day['timetable']
    if rows.empty?
      invalid! unless day['specialistWorkingHours'] == 'day off'
      return []
    end

    rows.filter_map { |row| window(row, date) }
  end

  def window(row, date)
    invalid! unless row.is_a?(Hash)
    flag = row['working']
    flag = flag.strip.downcase if flag.is_a?(String)
    working = Integrations::Medelement::TimetableWorking.normalize(flag)
    invalid! if working.nil?
    return unless working

    starts_at = parse_time(row['start'])
    ends_at = parse_time(row['end'])
    next_midnight = @time_zone.local((date + 1).year, (date + 1).month, (date + 1).day)
    invalid! unless starts_at.to_date == date && ends_at > starts_at && ends_at <= next_midnight

    [starts_at, ends_at, (row['cabinetCode'] || row['cabinet_code']).to_s.presence]
  end

  def parse_time(value)
    @time_zone.parse(value.to_s) || invalid!
  rescue ArgumentError, TypeError
    invalid!
  end

  def invalid!
    raise Integrations::Medelement::Client::InvalidTimetableError, 'Medelement timetable day is not confirmed'
  end
end
