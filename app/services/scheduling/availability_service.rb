class Scheduling::AvailabilityService
  Result = Struct.new(:available, :code, :message, keyword_init: true) do
    def available?
      available
    end
  end

  attr_reader :appointments, :from, :holidays, :ignore_appointment_id, :resource, :time_offs, :to, :workday_overrides

  def initialize(resource:, from:, to:, holidays:, workday_overrides:, time_offs:, appointments:, ignore_appointment_id: nil)
    @resource = resource
    @from = from
    @to = to
    @holidays = holidays
    @workday_overrides = workday_overrides
    @time_offs = time_offs
    @appointments = appointments
    @ignore_appointment_id = ignore_appointment_id
  end

  def available?(starts_at:, ends_at:)
    availability_result(starts_at: starts_at, ends_at: ends_at).available?
  end

  def availability_result(starts_at:, ends_at:)
    return Result.new(available: false, code: 'VALIDATION_ERROR', message: 'End date must be greater than start date') if ends_at <= starts_at

    local_date = local_booking_date(starts_at, ends_at)
    return Result.new(available: false, code: 'OUTSIDE_WORKING_HOURS', message: 'Appointment must fit into one local day') if local_date.nil?

    override = workday_overrides.find { |item| item.date == local_date }
    if holiday_blocks_date?(local_date) && override.blank?
      return Result.new(available: false, code: 'BLOCKED_BY_HOLIDAY', message: 'Date is blocked by holiday')
    end

    working_intervals = working_intervals_for_date(local_date, override)
    if working_intervals.empty?
      return Result.new(available: false, code: 'OUTSIDE_WORKING_HOURS', message: 'No working rules configured for this day')
    end

    unless inside_intervals?(working_intervals, starts_at: starts_at, ends_at: ends_at)
      return Result.new(available: false, code: 'OUTSIDE_WORKING_HOURS', message: 'Appointment is outside working hours')
    end

    if overlaps_intervals?(breaks_for_date(local_date, override), starts_at: starts_at, ends_at: ends_at)
      return Result.new(available: false, code: 'BLOCKED_BY_BREAK', message: 'Appointment overlaps resource break')
    end

    if overlaps_intervals?(time_off_intervals_for_date(local_date), starts_at: starts_at, ends_at: ends_at)
      return Result.new(available: false, code: 'BLOCKED_BY_VACATION', message: 'Appointment overlaps blocked time')
    end

    if overlaps_intervals?(appointment_intervals_for_date(local_date), starts_at: starts_at, ends_at: ends_at)
      return Result.new(available: false, code: 'SLOT_CONFLICT', message: 'Slot is already occupied')
    end

    Result.new(available: true)
  end

  def free_intervals
    @free_intervals ||= local_dates.flat_map do |date|
      day_intervals(date)
    end
  end

  def slots(duration_min:)
    duration = [duration_min.to_i, 5].max.minutes

    free_intervals.flat_map do |interval|
      build_slots_for_interval(interval, duration)
    end
  end

  private

  def inside_intervals?(intervals, starts_at:, ends_at:)
    intervals.any? { |interval| interval[0] <= starts_at && interval[1] >= ends_at }
  end

  def local_booking_date(starts_at, ends_at)
    start_date = starts_at.in_time_zone(time_zone).to_date
    end_date = (ends_at - 1.second).in_time_zone(time_zone).to_date
    return if end_date != start_date

    start_date
  end

  def overlaps_intervals?(intervals, starts_at:, ends_at:)
    intervals.any? { |interval| starts_at < interval[1] && interval[0] < ends_at }
  end

  def blocking_appointments
    appointments.select do |appointment|
      appointment.id != ignore_appointment_id && appointment.status != 'cancelled'
    end
  end

  def breaks_for_date(date, override)
    return override_breaks(date, override) if override.present?

    resource.break_rules.active.select { |rule| rule.weekday == date.wday }.map do |rule|
      [local_time(date, rule.start_minute), local_time(date, rule.end_minute)]
    end
  end

  def build_slots_for_interval(interval, duration)
    slots = []
    cursor = interval[0]

    while cursor + duration <= interval[1]
      slots << {
        resource_id: resource.id,
        starts_at: cursor.iso8601,
        ends_at: (cursor + duration).iso8601,
        status: 'available'
      }
      cursor += Scheduling::Constants::SLOT_STEP_MINUTES.minutes
    end

    slots
  end

  def day_bounds(date)
    day_start = time_zone.local(date.year, date.month, date.day, 0, 0, 0)
    [day_start, day_start + 1.day]
  end

  def day_intervals(date)
    override = workday_overrides.find { |item| item.date == date }
    base_intervals = working_intervals_for_date(date, override)
    return [] if base_intervals.empty?

    blocked = breaks_for_date(date, override) +
              time_off_intervals_for_date(date) +
              appointment_intervals_for_date(date)

    Scheduling::IntervalMath.subtract(base_intervals, blocked).filter_map do |interval|
      Scheduling::IntervalMath.clip(interval, from: from, to: to)
    end
  end

  def holiday_blocks_date?(date)
    matching_holidays = holidays.select { |holiday| holiday_matches_date?(holiday, date) }
    return false if matching_holidays.blank?
    return false if matching_holidays.any?(&:working_day_override?)

    true
  end

  def holiday_matches_date?(holiday, date)
    return holiday.date.month == date.month && holiday.date.day == date.day if holiday.recurring_yearly?

    holiday.date == date
  end

  def local_dates
    start_date = from.in_time_zone(time_zone).to_date
    end_date = (to - 1.second).in_time_zone(time_zone).to_date
    return [] if end_date < start_date

    (start_date..end_date).to_a
  end

  def local_time(date, minute_of_day)
    time_zone.local(date.year, date.month, date.day, minute_of_day / 60, minute_of_day % 60, 0)
  end

  def override_breaks(date, override)
    return [] if override.break_start_minute.blank? || override.break_end_minute.blank?

    [[local_time(date, override.break_start_minute), local_time(date, override.break_end_minute)]]
  end

  def appointment_intervals_for_date(date)
    day_start, day_end = day_bounds(date)

    blocking_appointments.filter_map do |appointment|
      next if appointment.ends_at <= day_start || appointment.starts_at >= day_end

      Scheduling::IntervalMath.clip([appointment.starts_at, appointment.ends_at], from: day_start, to: day_end)
    end
  end

  def time_off_intervals_for_date(date)
    day_start, day_end = day_bounds(date)

    time_offs.filter_map do |item|
      next if item.ends_at <= day_start || item.starts_at >= day_end

      Scheduling::IntervalMath.clip([item.starts_at, item.ends_at], from: day_start, to: day_end)
    end
  end

  def time_zone
    @time_zone ||= ActiveSupport::TimeZone[resource.timezone] || Time.zone
  end

  def working_intervals_for_date(date, override)
    return [[local_time(date, override.start_minute), local_time(date, override.end_minute)]] if override.present?
    return [] if holiday_blocks_date?(date)

    resource.work_rules.active.select { |rule| rule.weekday == date.wday }.map do |rule|
      [local_time(date, rule.start_minute), local_time(date, rule.end_minute)]
    end
  end
end
