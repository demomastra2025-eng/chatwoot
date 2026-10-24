# Finds the start grid a MedElement specialist is really booked on, from the receptions imported in the last 60 days, and stores a
# finer step than the reception time in custom_attributes.slot_grid_min (see Scheduling::SlotGrid).
#
# Some doctors book on 10-minute boundaries inside 30-minute cells; most are exactly on the cell grid. The coarsest step that holds
# at least 95% of the starts wins: when the reception time itself holds them, no override is needed and an old one is removed.
#
# A cell grid is anchored at the first cell of a day, which need not be on the clock (14:20 in 10-minute cells), so a start is on
# the grid of a step when it shares its remainder with most of the other starts of its day, not when the clock minute divides by
# the step. A day with a single start says nothing about a grid and is left out.
class Scheduling::SlotGridDetector
  WINDOW_DAYS = 60
  MIN_SHARE = 0.95
  MIN_STARTS = 20

  # status: finer (a finer step holds the starts: step_min), on_grid (the reception time holds them), irregular (no step holds
  # them) or insufficient (too few starts in days with several of them). share is that of step_min, or of the reception time.
  Result = Data.define(:resource_id, :status, :reception_min, :step_min, :share, :starts)

  def self.run(scope:, apply: false, now: Time.current)
    scope.find_each.filter_map do |resource|
      next unless Scheduling::SlotGrid.provider?(resource)

      detector = new(resource: resource, now: now)
      detector.perform.tap { |result| detector.apply!(result) if apply }
    end
  end

  def initialize(resource:, now: Time.current)
    @resource = resource
    @now = now
  end

  def perform
    reception = Scheduling::SlotGrid.base_step_minutes(@resource)
    days = starts_by_day
    starts = days.values.sum(&:size)
    return result('insufficient', reception, nil, nil, starts) if starts < MIN_STARTS

    share = share_of(days, reception, starts)
    return result('on_grid', reception, nil, share, starts) if share >= MIN_SHARE

    step = finer_steps(reception).find { |candidate| share_of(days, candidate, starts) >= MIN_SHARE }
    return result('irregular', reception, nil, share, starts) unless step

    result('finer', reception, step, share_of(days, step, starts), starts)
  end

  # Stores the finer step, or removes the stored one when the reception grid holds; an unclear result changes nothing.
  def apply!(result)
    return false unless result.status.in?(%w[finer on_grid])

    @resource.with_lock do
      attributes = @resource.custom_attributes.to_h
      stored = attributes[Scheduling::SlotGrid::OVERRIDE_KEY]
      wanted = result.step_min
      next false if stored == wanted

      wanted ? attributes[Scheduling::SlotGrid::OVERRIDE_KEY] = wanted : attributes.delete(Scheduling::SlotGrid::OVERRIDE_KEY)
      @resource.update!(custom_attributes: attributes)
      true
    end
  end

  private

  def result(status, reception, step, share, starts)
    Result.new(resource_id: @resource.id, status: status, reception_min: reception, step_min: step, share: share&.round(4),
               starts: starts)
  end

  # The steps finer than the reception time that divide it, in whole 5 minutes, the coarsest first.
  def finer_steps(reception)
    unit = Scheduling::Constants::SLOT_STEP_MINUTES
    (unit...reception).step(unit).select { |step| (reception % step).zero? }.reverse
  end

  # The share of the starts that sit on the grid of a step: per day, the starts of the most common remainder.
  def share_of(days, step, starts)
    on_grid = days.values.sum { |minutes| minutes.map { |minute| minute % step }.tally.values.max }
    on_grid.fdiv(starts)
  end

  # { date => [minute of the day, ...] } of the imported receptions of the window, only days with several starts.
  def starts_by_day
    zone = ActiveSupport::TimeZone[@resource.timezone] || Time.zone
    starts = @resource.appointments.where(source: 'medelement').where.not(status: 'cancelled')
                      .where(starts_at: (@now - WINDOW_DAYS.days)...@now).pluck(:starts_at)
    days = starts.map { |time| time.in_time_zone(zone) }.group_by(&:to_date)
    days.transform_values { |times| times.map { |time| (time.hour * 60) + time.min } }.select { |_date, minutes| minutes.size > 1 }
  end
end
