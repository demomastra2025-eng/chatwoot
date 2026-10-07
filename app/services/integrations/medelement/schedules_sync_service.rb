class Integrations::Medelement::SchedulesSyncService
  SCHEDULE_HORIZON_DAYS = 14
  REQUEST_CAP = 300
  NEAR_REFRESH = 1.hour
  FAR_REFRESH = 12.hours
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
    by_resource = due.group_by { |resource, _date, _stored| resource.id }
    selected = by_resource.values.first(REQUEST_CAP)
    @counters[:skipped_count] = due.size - selected.sum(&:size)
    selected.each { |days| refresh(days) }
    @counters
  end

  private

  attr_reader :client, :configuration, :hook, :now, :today

  def due_days
    candidates = []
    resources.find_in_batches(batch_size: 100) { |batch| candidates.concat(due_days_for_batch(batch)) }
    candidates.sort_by do |resource, date, stored|
      checked_at = stored&.status == 'unverified' ? stored.last_attempted_at : stored&.source_checked_at
      [checked_at || Time.zone.at(0), date, resource.id]
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
    checked_at = stored&.source_checked_at
    checked_at.nil? || checked_at <= now - (offset < 2 ? NEAR_REFRESH : FAR_REFRESH)
  end

  def refresh(days)
    resource = days.first.first
    dates = days.map { |_resource, date, _stored| date }
    @counters[:request_count] += 1
    payload = client.timetable(specialist_code: resource.custom_attributes[SPECIALIST_CODE_KEY].to_s,
                               starts_on: dates.min, ends_on: dates.max, allow_partial: true)
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
    empty_count = windows.empty? ? record.consecutive_empty_count + 1 : 0
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
    record.update!(status: 'unverified', consecutive_empty_count: 0, last_attempted_at: now)
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
