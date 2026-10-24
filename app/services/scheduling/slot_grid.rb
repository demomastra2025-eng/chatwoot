# The grid of visit starts of one specialist.
#
# MedElement cuts a working day into cells of the specialist's reception time (10, 15, 20 or 30 minutes) and a visit starts at the
# beginning of a cell, so 14:20-20:00 in 10-minute cells offers 14:20, 14:30, ... and never 14:25. Joining the touching cells into
# one working interval loses the cell starts, so the cells stay the anchors of the starts and the step runs from them.
#
# The step is the reception time (MedElement) or slot_duration_min (a specialist without MedElement hours), unless the resource
# says a finer one in custom_attributes.slot_grid_min: some doctors book on 10-minute boundaries inside 30-minute cells. The
# override only ever refines the grid (it must divide the reception time), so it can add starts and never moves a cell start.
module Scheduling::SlotGrid
  OVERRIDE_KEY = 'slot_grid_min'.freeze
  RECEPTION_TIME_KEY = 'medelement_reception_time'.freeze
  SPECIALIST_CODE_KEY = 'medelement_specialist_code'.freeze
  MIN_STEP_MINUTES = Scheduling::Constants::SLOT_STEP_MINUTES
  DEFAULT_STEP_MINUTES = 30

  module_function

  # A specialist whose hours come from MedElement: the specialist code is what links the resource to the provider.
  def provider?(resource)
    custom_attributes(resource)[SPECIALIST_CODE_KEY].present?
  end

  # The step between two starts, in minutes.
  def step_minutes(resource)
    base = base_step_minutes(resource)
    finer = whole_minutes(custom_attributes(resource)[OVERRIDE_KEY])
    refines?(finer, base) ? finer : base
  end

  # An override counts only when it is a finer step that divides the base step, so it adds starts inside the cells.
  def refines?(finer, base)
    finer.present? && finer.between?(MIN_STEP_MINUTES, base - 1) && (base % finer).zero?
  end

  # The step without the override: the cell the provider cuts, or the visit length a local specialist is booked by.
  def base_step_minutes(resource)
    reception = whole_minutes(custom_attributes(resource)[RECEPTION_TIME_KEY]) if provider?(resource)
    configured = reception || (whole_minutes(resource.slot_duration_min) if resource.respond_to?(:slot_duration_min))
    [configured || DEFAULT_STEP_MINUTES, MIN_STEP_MINUTES].max
  end

  # Every start of a visit of `duration` that lies inside one free interval. From each cell that reaches into the interval the
  # starts are the cell start and every step after it that is still inside the cell and still leaves room for the whole visit.
  # A free interval that begins mid-cell (after a visit that ended off the grid) begins at the next grid start of its cell.
  def starts(cells:, interval:, step_minutes:, duration:)
    latest = interval.last - duration
    step = step_minutes * 60
    cells.flat_map { |cell| cell_starts(cell, interval.first, latest, step) }.uniq(&:to_i).sort_by(&:to_i)
  end

  # True when the start is a cell start or a whole number of steps after one, inside that cell.
  def on_grid?(starts_at, cells:, step_minutes:)
    step = step_minutes * 60
    cells.any? do |cell|
      cell.first <= starts_at && starts_at < cell.last && ((starts_at.to_i - cell.first.to_i) % step).zero?
    end
  end

  # The grid starts just before and just after a time: [previous, following], either of them nil when there is none.
  def neighbours(starts_at, cells:, step_minutes:)
    return [nil, nil] if cells.empty?

    all = starts(cells: cells, interval: [cells.map(&:first).min, cells.map(&:last).max], step_minutes: step_minutes, duration: 0)
    [all.reverse.find { |time| time < starts_at }, all.find { |time| time > starts_at }]
  end

  def cell_starts(cell, earliest, latest, step)
    first = [cell.first, earliest].max
    return [] if first > latest || cell.last <= first

    start = cell.first + ((first.to_i - cell.first.to_i + step - 1).div(step) * step)
    times = []
    while start <= latest && start < cell.last
      times << start
      start += step
    end
    times
  end

  def custom_attributes(resource)
    resource.respond_to?(:custom_attributes) ? resource.custom_attributes.to_h : {}
  end

  # A positive whole number of minutes from a number or a numeric string ("30", 30, 30.0); anything else is no value.
  def whole_minutes(value)
    number = Float(value, exception: false)
    return unless number&.finite? && number.positive? && number == number.floor

    number.to_i
  end
end
