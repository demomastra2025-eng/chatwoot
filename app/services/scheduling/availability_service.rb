class Scheduling::AvailabilityService
  include Scheduling::AvailabilityRefusals

  Result = Scheduling::AvailabilityResult

  attr_reader :appointments, :from, :holidays, :ignore_appointment_id, :resource, :time_offs, :to, :workday_overrides

  # rubocop:disable Metrics/ParameterLists
  def initialize(resource:, from:, to:, holidays:, workday_overrides:, time_offs:, appointments:, ignore_appointment_id: nil,
                 provider_working_windows: nil, replace_work_rules: false)
    @resource = resource
    @from = from
    @to = to
    @holidays = holidays
    @workday_overrides = workday_overrides
    @time_offs = time_offs
    @appointments = appointments
    @ignore_appointment_id = ignore_appointment_id
    @provider_working_windows = provider_working_windows
    @replace_work_rules = replace_work_rules
  end
  # rubocop:enable Metrics/ParameterLists

  def available?(starts_at:, ends_at:)
    availability_result(starts_at: starts_at, ends_at: ends_at).available?
  end

  # enforce_grid: a start that is not on the grid of a MedElement specialist is refused (a booking chooses its start; the checks of
  # an existing visit that keeps its start pass false).
  def availability_result(starts_at:, ends_at:, enforce_grid: false)
    return unavailable('VALIDATION_ERROR', 'End date must be greater than start date') if ends_at <= starts_at

    local_date = local_booking_date(starts_at, ends_at)
    return unavailable('OUTSIDE_WORKING_HOURS', 'Appointment must fit into one local day') if local_date.nil?

    override = workday_overrides.find { |item| item.date == local_date }
    working_time_failure(local_date, override, starts_at, ends_at, enforce_grid) ||
      blocked_time_failure(local_date, override, starts_at, ends_at) ||
      Result.new(available: true)
  end

  def free_intervals
    @free_intervals ||= local_dates.flat_map { |date| day_intervals(date) }
  end

  # Every start of a visit that fits a free interval, on the grid of the specialist (see Scheduling::SlotGrid).
  def slots(duration_min:)
    duration = [duration_min.to_i, Scheduling::Constants::MIN_DURATION_MINUTES].max.minutes

    local_dates.flat_map { |date| day_slots(date, duration) }
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
      appointment.id != ignore_appointment_id &&
        (appointment.status != 'cancelled' || Integrations::Medelement::LocalCancellation.provider_occupied?(appointment))
    end
  end

  def breaks_for_date(date, override)
    return override_breaks(date, override) if override.present?

    resource.break_rules.active.select { |rule| rule.weekday == date.wday }.map do |rule|
      [local_time(date, rule.start_minute), local_time(date, rule.end_minute)]
    end
  end

  # The slots of one local date: the grid starts (anchored at the cells of the day, not at the free interval) of each free interval.
  def day_slots(date, duration)
    override = workday_overrides.find { |item| item.date == date }
    cells = working_cells_for_date(date, override)

    free_intervals_for(date, override, merge_working(cells)).flat_map do |interval|
      Scheduling::SlotGrid.starts(cells: cells, interval: interval, step_minutes: grid_step, duration: duration).map do |start|
        { resource_id: resource.id, starts_at: start.iso8601, ends_at: (start + duration).iso8601, status: 'available' }
      end
    end
  end

  def day_bounds(date)
    day_start = time_zone.local(date.year, date.month, date.day, 0, 0, 0)
    [day_start, day_start + 1.day]
  end

  def day_intervals(date)
    override = workday_overrides.find { |item| item.date == date }
    free_intervals_for(date, override, working_intervals_for_date(date, override))
  end

  def free_intervals_for(date, override, base_intervals)
    return [] if base_intervals.empty?

    blocked = if @replace_work_rules
                appointment_intervals_for_date(date)
              else
                breaks_for_date(date, override) +
                  time_off_intervals_for_date(date) +
                  appointment_intervals_for_date(date)
              end

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
    merge_working(working_cells_for_date(date, override))
  end

  # The working time of a date as the schedule gives it, one entry per cell: a MedElement cell of the specialist's reception time,
  # or a work rule (a workday override) of a local specialist. The cells are the anchors of the grid of starts.
  def working_cells_for_date(date, override)
    return provider_cells(date) if @replace_work_rules
    return [] if holiday_blocks_date?(date) && override.blank?

    local = local_cells(date, override)
    @provider_working_windows.nil? ? local : intersect_cells(provider_cells(date), local)
  end

  def local_cells(date, override)
    return [[local_time(date, override.start_minute), local_time(date, override.end_minute)]] if override.present?

    resource.work_rules.active.select { |rule| rule.weekday == date.wday }.map do |rule|
      [local_time(date, rule.start_minute), local_time(date, rule.end_minute)]
    end
  end

  def provider_cells(date)
    day_start, day_end = day_bounds(date)
    Array(@provider_working_windows).filter_map do |interval|
      Scheduling::IntervalMath.clip(interval, from: day_start, to: day_end)
    end
  end

  def intersect_cells(provider, local)
    provider.flat_map do |provider_cell|
      local.filter_map { |local_cell| Scheduling::IntervalMath.clip(provider_cell, from: local_cell.first, to: local_cell.last) }
    end
  end

  # Provider hours are joined into working intervals (a visit may run over several touching cells); local work rules stay apart.
  def merge_working(cells)
    @replace_work_rules || !@provider_working_windows.nil? ? merge_intervals(cells) : cells
  end

  def merge_intervals(intervals)
    intervals.sort_by(&:first).each_with_object([]) do |interval, merged|
      if merged.any? && merged.last.last >= interval.first
        merged.last[1] = [merged.last.last, interval.last].max
      else
        merged << interval.dup
      end
    end
  end
end
