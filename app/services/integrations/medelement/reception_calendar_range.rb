class Integrations::Medelement::ReceptionCalendarRange
  def self.for(starts_at, ends_at, time_zone:)
    zone = ActiveSupport::TimeZone[time_zone]
    starts_on = starts_at.in_time_zone(zone).to_date
    ends_on = ends_at.in_time_zone(zone).to_date + 1.day

    Range.new(
      zone.local(starts_on.year, starts_on.month, starts_on.day),
      zone.local(ends_on.year, ends_on.month, ends_on.day),
      true
    )
  end
end
