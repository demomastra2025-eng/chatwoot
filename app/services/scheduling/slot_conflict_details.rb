class Scheduling::SlotConflictDetails
  Occupied = Struct.new(:id, :status, :starts_at, :ends_at)

  def self.for_provider(resource:, interval:, windows:, receptions:, ignore_appointment_id: nil)
    starts_at, ends_at = interval
    zone = ActiveSupport::TimeZone[resource.timezone] || Time.zone
    date = starts_at.in_time_zone(zone).to_date
    day_start = zone.local(date.year, date.month, date.day)
    day_end = day_start + 1.day
    appointments = provider_appointments(resource, day_start, day_end, receptions)
    availability = Scheduling::AvailabilityService.new(
      resource: resource, from: day_start, to: day_end, holidays: [], workday_overrides: [], time_offs: [],
      appointments: appointments, ignore_appointment_id: ignore_appointment_id,
      provider_working_windows: windows, replace_work_rules: true
    )
    new(availability: availability, starts_at: starts_at, ends_at: ends_at, free_starts_known: !windows.nil?).perform
  end

  def self.provider_appointments(resource, day_start, day_end, receptions)
    local = resource.account.scheduling_appointments.where(resource_id: resource.id)
                    .where('starts_at < ? AND ends_at > ?', day_end, day_start).to_a
    local + receptions.map { |first, last| Occupied.new(nil, 'scheduled', first, last) }
  end

  def initialize(availability:, starts_at:, ends_at:, occupied_intervals: nil, free_starts_known: true)
    @availability = availability
    @starts_at = starts_at
    @ends_at = ends_at
    @occupied_intervals = occupied_intervals
    @free_starts_known = free_starts_known
  end

  def perform
    busy = busy_interval
    return {} unless busy

    details = {
      busy: { starts_at: busy.first.iso8601, ends_at: busy.last.iso8601 },
      time_zone: @availability.resource.timezone
    }
    details[:free_starts] = free_starts(busy) if @free_starts_known
    details
  rescue StandardError => e
    Rails.logger.warn("[SCHEDULING::CONFLICT_DETAILS] error=#{e.class.name}")
    {}
  end

  private

  def blocking_intervals
    return @occupied_intervals if @occupied_intervals

    @availability.appointments.filter_map do |appointment|
      next if appointment.id == @availability.ignore_appointment_id
      next if appointment.status == 'cancelled' && !Integrations::Medelement::LocalCancellation.provider_occupied?(appointment)

      [appointment.starts_at, appointment.ends_at]
    end
  end

  def busy_interval
    overlapping = merge_intervals(blocking_intervals).select do |first, last|
      first < @ends_at && last > @starts_at
    end
    [overlapping.first.first, overlapping.last.last] if overlapping.any?
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

  def free_starts(busy)
    day = @starts_at.in_time_zone(@availability.resource.timezone).to_date
    duration = ((@ends_at - @starts_at) / 60).ceil
    starts = candidate_starts(duration, day)
    (starts.select { |start| start < busy.first }.last(2) +
      starts.select { |start| start >= busy.last }.first(2)).map(&:iso8601)
  end

  def candidate_starts(duration, day)
    @availability.slots(duration_min: duration).filter_map do |slot|
      start = Time.iso8601(slot.fetch(:starts_at))
      start if start >= Time.current && start.in_time_zone(@availability.resource.timezone).to_date == day
    end
  end
end
