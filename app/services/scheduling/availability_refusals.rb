# The reasons Scheduling::AvailabilityService refuses the time of a booking, in the order they are checked: a blocked date, the
# working hours of the day, the grid of the specialist's cells, then what occupies the time (a break, time off, another visit).
# Each check answers nil when the time passes it, else the refusal as a Scheduling::AvailabilityResult.
module Scheduling::AvailabilityRefusals
  private

  def working_time_failure(date, override, starts_at, ends_at, enforce_grid)
    holiday_failure(date, override) || hours_failure(date, override, starts_at, ends_at, enforce_grid)
  end

  def holiday_failure(date, override)
    return if @replace_work_rules || override.present? || !holiday_blocks_date?(date)

    unavailable('BLOCKED_BY_HOLIDAY', 'Date is blocked by holiday')
  end

  def hours_failure(date, override, starts_at, ends_at, enforce_grid)
    cells = working_cells_for_date(date, override)
    intervals = merge_working(cells)
    return unavailable('OUTSIDE_WORKING_HOURS', 'No working rules configured for this day') if intervals.empty?

    unless inside_intervals?(intervals, starts_at: starts_at, ends_at: ends_at)
      return unavailable('OUTSIDE_WORKING_HOURS', 'Appointment is outside working hours')
    end

    off_grid_failure(cells, starts_at) if enforce_grid && grid_enforced?
  end

  def blocked_time_failure(date, override, starts_at, ends_at)
    period = { starts_at: starts_at, ends_at: ends_at }
    if !@replace_work_rules && overlaps_intervals?(breaks_for_date(date, override), **period)
      unavailable('BLOCKED_BY_BREAK', 'Appointment overlaps resource break')
    elsif !@replace_work_rules && overlaps_intervals?(time_off_intervals_for_date(date), **period)
      unavailable('BLOCKED_BY_VACATION', 'Appointment overlaps blocked time')
    elsif overlaps_intervals?(appointment_intervals_for_date(date), **period)
      unavailable('SLOT_CONFLICT', 'Slot is already occupied')
    end
  end

  # The grid is enforced for a MedElement specialist whose cells the provider gave and whose grid is verified (the detector or a
  # person settled it, see Scheduling::SlotGrid.verified?); it is the step of Scheduling::SlotGrid. Until then a start the specialist
  # really books on, inside a cell, is not refused.
  def grid_enforced?
    @replace_work_rules && !@provider_working_windows.nil? && Scheduling::SlotGrid.provider?(resource) &&
      Scheduling::SlotGrid.verified?(resource)
  end

  def grid_step
    @grid_step ||= Scheduling::SlotGrid.step_minutes(resource)
  end

  # The refusal names the grid and the starts next to the asked one, so the caller can offer them.
  def off_grid_failure(cells, starts_at)
    return if Scheduling::SlotGrid.on_grid?(starts_at, cells: cells, step_minutes: grid_step)

    nearest = Scheduling::SlotGrid.neighbours(starts_at, cells: cells, step_minutes: grid_step).compact
    unavailable('START_OFF_GRID', off_grid_message(starts_at, nearest),
                { step_min: grid_step, nearest_starts: nearest.map(&:iso8601) })
  end

  def off_grid_message(starts_at, nearest)
    clocks = nearest.map { |time| time.in_time_zone(time_zone).strftime('%H:%M') }
    "Start #{starts_at.in_time_zone(time_zone).strftime('%H:%M')} is not on the specialist's schedule grid " \
      "(visits start every #{grid_step} minutes from the start of a cell); nearest starts: #{clocks.join(' or ')}"
  end

  def unavailable(code, message, details = nil)
    Scheduling::AvailabilityResult.new(available: false, code: code, message: message, details: details)
  end
end
