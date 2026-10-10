module Captain::Playground::AvailabilityTools
  private

  def parse_time(value)
    raise ArgumentError, 'Datetime must include an explicit timezone' unless value.to_s.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)

    Time.iso8601(value.to_s)
  rescue ArgumentError
    raise ArgumentError, 'Invalid ISO 8601 datetime with timezone'
  end

  def duration_for(resource, service_id, duration_min)
    service = service!(service_id, resource: resource) if service_id.present?
    duration = Integer(duration_min || service&.fetch('duration_min', nil) || 30)
    raise ArgumentError, 'Duration must be between 5 and 240 minutes' unless duration.between?(5, 240)

    duration
  end

  def slot_available?(resource, starts_at, ends_at, exclude_id: nil)
    return false unless within_clinic_hours?(starts_at, ends_at)

    @data['appointments'].none? do |record|
      record['id'] != exclude_id && record['resource_id'] == resource['id'] && record['status'] != 'cancelled' &&
        parse_time(record['starts_at']) < ends_at && parse_time(record['ends_at']) > starts_at
    end
  end

  def within_clinic_hours?(starts_at, ends_at)
    local_start = starts_at.in_time_zone(@data['timezone'])
    local_end = ends_at.in_time_zone(@data['timezone'])
    local_start.to_date == local_end.to_date && local_start.hour >= 9 && local_end.hour <= 18 &&
      (local_end.hour < 18 || local_end.min.zero?)
  end

  def available_slots
    from = parse_time(@args.fetch('from'))
    to = parse_time(@args.fetch('to'))
    raise ArgumentError, 'Availability range must be positive and at most 14 days' unless to > from && to - from <= 14.days

    resources = availability_resources
    window = { from: from, to: to, limit: Integer(@args['limit'] || 20).clamp(1, 100) }
    slots = []
    resources.each { |resource| append_resource_slots(slots, resource, window) }
    { slots: slots.sort_by { |slot| slot[:starts_at] }, total_slots: slots.size, requested_service_id: @args['service_id'],
      service_match: { confirmed: @args['service_id'].present?, resource_ids: resources.map { |resource| resource['id'] } }, simulated: true }
  end
end
