class Scheduling::ResourceAvailabilityQueryService
  MAX_LIMIT = 50
  MAX_RANGE_DAYS = Scheduling::RangeValidator::MAX_RANGE_DAYS

  def initialize(resource:, from:, to:, service: nil, duration_min: nil, limit: nil)
    @resource = resource
    @account = resource.account
    @from = from
    @to = to
    @service = service
    @duration_min = duration_for(service: service, duration_min: duration_min)
    @limit = normalize_limit(limit)
  end

  def perform
    validate_range!

    slots = available_slots

    {
      resource: Scheduling::PayloadBuilder.resource(@resource),
      service: @service.present? ? Scheduling::PayloadBuilder.service(@service) : nil,
      timezone: time_zone.tzinfo.name,
      range: {
        from: @from.iso8601,
        to: @to.iso8601
      },
      duration_min: @duration_min,
      slots: slots,
      total_slots: slots.length
    }.compact
  end

  private

  def available_slots
    @available_slots ||= availability_service.slots(duration_min: @duration_min).first(@limit).map do |slot|
      {
        resource_id: slot[:resource_id],
        starts_at: Time.zone.parse(slot[:starts_at]).in_time_zone(time_zone).iso8601,
        ends_at: Time.zone.parse(slot[:ends_at]).in_time_zone(time_zone).iso8601,
        duration_min: @duration_min,
        status: slot[:status]
      }
    end
  end

  def availability_service
    @availability_service ||= Scheduling::AvailabilityService.new(
      resource: @resource,
      from: @from,
      to: @to,
      holidays: @account.scheduling_holidays.ordered.to_a,
      workday_overrides: @resource.workday_overrides.where(date: local_date_window).ordered.to_a,
      time_offs: @account.scheduling_time_offs.where(resource_id: [nil, @resource.id]).where('starts_at < ? AND ends_at > ?', @to,
                                                                                             @from).ordered.to_a,
      appointments: @account.scheduling_appointments.where(resource_id: @resource.id).where('starts_at < ? AND ends_at > ?', @to, @from).ordered.to_a
    )
  end

  def duration_for(service:, duration_min:)
    return service.duration_min if service.present?

    numeric = duration_min.to_i
    return @resource.slot_duration_min if numeric <= 0

    numeric
  end

  def validate_range!
    Scheduling::RangeValidator.validate!(from: @from, to: @to, max_days: MAX_RANGE_DAYS)
  end

  def normalize_limit(value)
    numeric = value.to_i
    return MAX_LIMIT if numeric <= 0

    [numeric, MAX_LIMIT].min
  end

  def local_date_window
    (@from.to_date - 1)..(@to.to_date + 1)
  end

  def time_zone
    @time_zone ||= ActiveSupport::TimeZone[@resource.timezone] || Time.zone
  end
end
