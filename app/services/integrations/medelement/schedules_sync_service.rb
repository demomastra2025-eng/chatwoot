# MEDELEMENT_SCHEDULE_REQUEST_CAP (default 600) limits all windows per hook and run.
# MEDELEMENT_SCHEDULE_FIRST_FILL_CAP (default 40) separately limits windows with no shadow row.
class Integrations::Medelement::SchedulesSyncService
  SCHEDULE_HORIZON_DAYS = 90
  REQUEST_CAP = 600
  FIRST_FILL_CAP = 40
  FAILURE_BACKOFF = 15.minutes
  MAX_FAILURE_BACKOFF = 6.hours
  NEAR_REFRESH = 1.hour
  FAR_REFRESH = 12.hours
  LONG_REFRESH = 24.hours
  LAST_SEEN_MAX_AGE = 1.hour
  SPECIALIST_CODE_KEY = Integrations::Medelement::SpecialistsSyncService::SPECIALIST_CODE_KEY
  LAST_SEEN_AT_KEY = Integrations::Medelement::SpecialistsSyncService::LAST_SEEN_AT_KEY

  def initialize(hook:, client:, configuration:, now: Time.current)
    @hook = hook
    @client = client
    @configuration = configuration
    @now = now
  end

  def perform
    @today = now.in_time_zone(configuration.time_zone).to_date
    @counters = { created_count: 0, updated_count: 0, unverified_count: 0, skipped_count: 0, request_count: 0 }
    due = due_days
    selected = select_windows(due)
    @counters[:skipped_count] = due.size
    first_error = nil
    rate_limited = false
    selected.each do |days|
      @counters[:skipped_count] -= days.size
      refresh(days)
    rescue Integrations::Medelement::Client::ApiError => e
      if e.status == 429
        rate_limited = true
        break
      end

      first_error ||= e
    end
    raise first_error if first_error
    return @counters if rate_limited

    prune_old_days
    @counters
  end

  private

  attr_reader :client, :configuration, :hook, :now, :today

  def due_days
    candidates = []
    resources.find_in_batches(batch_size: 100) { |batch| candidates.concat(due_days_for_batch(batch)) }
    candidates.sort_by do |resource, date, stored|
      checked_at = stored&.status == 'unverified' ? stored.last_attempted_at : stored&.source_checked_at
      [date < today + 2 ? 0 : 1, stored.nil? ? 1 : 0, checked_at || Time.zone.at(0), date, resource.id]
    end
  end

  def due_days_for_batch(batch)
    existing = Integrations::Medelement::ScheduleDay.where(
      account_id: hook.account_id, hook_id: hook.id, resource_id: batch.map(&:id),
      date: today...(today + SCHEDULE_HORIZON_DAYS)
    ).index_by { |day| [day.resource_id, day.date] }
    batch.flat_map { |resource| due_days_for_resource(resource, existing) }
  end

  def due_days_for_resource(resource, existing)
    return [] unless recently_polled?(resource)

    SCHEDULE_HORIZON_DAYS.times.filter_map do |offset|
      date = today + offset
      stored = existing[[resource.id, date]]
      [resource, date, stored] if due?(stored, offset)
    end
  end

  def resources
    hook.account.scheduling_resources.available_for_scheduling
        .where("NULLIF(custom_attributes ->> '#{SPECIALIST_CODE_KEY}', '') IS NOT NULL")
  end

  def recently_polled?(resource)
    value = resource.custom_attributes[LAST_SEEN_AT_KEY]
    value.present? && Time.iso8601(value) >= now - LAST_SEEN_MAX_AGE
  rescue ArgumentError, TypeError
    false
  end

  def due?(stored, offset)
    return false if retry_backoff?(stored)

    checked_at = stored&.source_checked_at
    refresh_interval = if offset < 2
                         NEAR_REFRESH
                       elsif offset < 14
                         FAR_REFRESH
                       else
                         LONG_REFRESH
                       end
    checked_at.nil? || checked_at <= now - refresh_interval
  end

  def retry_backoff?(stored)
    return false unless stored&.status == 'unverified' && stored.last_attempted_at

    exponent = (stored.consecutive_empty_count - 1).clamp(0, 5)
    delay = [FAILURE_BACKOFF * (2**exponent), MAX_FAILURE_BACKOFF].min
    stored.last_attempted_at > now - delay
  end

  def due_windows(due)
    priority = due.each_with_index.to_h { |(resource, date, _stored), index| [[resource.id, date], index] }
    windows = due.group_by { |resource, _date, _stored| resource.id }.values.flat_map { |days| windows_for_resource(days) }
    windows.sort_by { |days| days.map { |resource, date, _stored| priority.fetch([resource.id, date]) }.min }
  end

  def select_windows(due)
    total_cap = env_cap('MEDELEMENT_SCHEDULE_REQUEST_CAP', REQUEST_CAP)
    fill_cap = env_cap('MEDELEMENT_SCHEDULE_FIRST_FILL_CAP', FIRST_FILL_CAP)
    selected = []
    fills = 0
    due_windows(due).each do |window|
      break if selected.size >= total_cap
      next if window.first.last.nil? && fills >= fill_cap

      selected << window
      fills += 1 if window.first.last.nil?
    end
    selected
  end

  def env_cap(name, default)
    value = Integer(ENV.fetch(name, default))
    value.positive? ? value : default
  rescue ArgumentError, TypeError
    default
  end

  def windows_for_resource(days)
    days.sort_by { |_resource, date, _stored| date }.each_with_object([]) do |day, windows|
      window = windows.last
      if window && day[2].nil? == window.last[2].nil? &&
         day[1] == window.last[1] + 1 &&
         day[1] <= window.first[1] + Integrations::Medelement::Client::MAX_TIMETABLE_DAYS - 1
        window << day
      else
        windows << [day]
      end
    end
  end

  def prune_old_days
    scope = Integrations::Medelement::ScheduleDay.where(account_id: hook.account_id, hook_id: hook.id)
    scope.where('date < ?', today - 1).delete_all
  end

  def refresh(days)
    resource = days.first.first
    dates = days.map { |_resource, date, _stored| date }
    @counters[:request_count] += 1
    payload = client.timetable(specialist_code: resource.custom_attributes[SPECIALIST_CODE_KEY].to_s,
                               starts_on: dates.min, ends_on: dates.max, allow_partial: true, retry_429: false)
    days.each do |_day_resource, date, stored|
      day = payload[date.strftime('%d.%m.%Y')] if payload.is_a?(Hash)
      kind, windows = classify_day(day, date)
      kind == :unverified ? mark_unverified(resource, date, stored) : persist_day(resource, date, stored, windows, day)
    end
  rescue Integrations::Medelement::Client::ApiError
    days.each { |_day_resource, date, stored| mark_unverified(resource, date, stored) }
    raise
  end

  def classify_day(day, date)
    rows = timetable_rows(day)
    return [:unverified, nil] unless rows
    return [:day_off, []] if rows.empty? && day['specialistWorkingHours'] == 'day off'
    return [:unverified, nil] if rows.empty? || !valid_working_hours?(day['specialistWorkingHours'], date)

    windows = normalized_windows(rows, date)
    return [:unverified, nil] if windows.nil? || windows.empty?

    [:working, windows]
  end

  def valid_working_hours?(hours, date)
    return false unless hours.is_a?(Hash)

    start_minute = minute_of_day(hours['start'], date)
    end_minute = minute_of_day(hours['end'], date, allow_next_midnight: true)
    start_minute && end_minute && end_minute > start_minute
  end

  def normalized_windows(rows, date)
    windows = rows.filter_map { |row| normalized_window(row, date) }
    return if windows.include?(:invalid)

    windows.sort_by { |window| window[:start_minute] }
  end

  def timetable_rows(day)
    return unless day.is_a?(Hash) && day['timetable'].is_a?(Array)

    rows = day['timetable']
    return unless rows.all?(Hash)
    return unless rows.all? { |row| !Integrations::Medelement::TimetableWorking.normalize(row['working']).nil? }

    rows
  end

  def normalized_window(row, date)
    return unless Integrations::Medelement::TimetableWorking.working?(row['working'])

    start_minute = minute_of_day(row['start'], date)
    end_minute = minute_of_day(row['end'], date, allow_next_midnight: true)
    return :invalid if start_minute.nil? || end_minute.nil? || end_minute <= start_minute

    {
      start_minute: start_minute, end_minute: end_minute,
      cabinet_code: row['cabinetCode'] || row['cabinet_code'],
      working: row['working'], type: row['type']
    }.compact
  end

  def minute_of_day(value, date, allow_next_midnight: false)
    parsed = DateTime.strptime(value.to_s, '%d.%m.%Y %H:%M')
    return (parsed.hour * 60) + parsed.minute if parsed.to_date == date
    return 1440 if allow_next_midnight && parsed.to_date == date + 1 && parsed.hour.zero? && parsed.minute.zero?
  rescue ArgumentError, TypeError
    nil
  end

  def persist_day(resource, date, stored, windows, day)
    record = stored || new_day(resource, date)
    empty_count = if windows.any?
                    0
                  elsif record.status == 'unverified'
                    1
                  else
                    record.consecutive_empty_count + 1
                  end
    status = day_status(windows, empty_count)
    record.assign_attributes(
      windows: status == 'empty_confirmed' || windows.any? ? windows : record.windows,
      status: status, consecutive_empty_count: empty_count,
      source_checked_at: now, last_attempted_at: now,
      raw_digest: Digest::SHA256.hexdigest(JSON.generate(day))
    )
    record.save!
    @counters[stored ? :updated_count : :created_count] += 1
  end

  def day_status(windows, empty_count)
    return 'confirmed' if windows.any?
    return 'empty_confirmed' if empty_count >= 2

    'empty_unconfirmed'
  end

  def mark_unverified(resource, date, stored)
    record = stored || new_day(resource, date)
    failures = record.status == 'unverified' ? record.consecutive_empty_count + 1 : 1
    record.update!(status: 'unverified', consecutive_empty_count: failures, last_attempted_at: now)
    @counters[:unverified_count] += 1
    Rails.logger.warn(
      "[MEDELEMENT::SCHEDULES_SYNC] Unverified day account=#{hook.account_id} hook=#{hook.id} " \
      "resource_id=#{resource.id} date=#{date}"
    )
  end

  def new_day(resource, date)
    Integrations::Medelement::ScheduleDay.new(
      account: hook.account, hook: hook, resource: resource,
      specialist_code: resource.custom_attributes[SPECIALIST_CODE_KEY].to_s, date: date
    )
  end
end
