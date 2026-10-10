module Captain::Playground::SlotCalendar
  private

  def append_resource_slots(slots, resource, window)
    zone = ActiveSupport::TimeZone[@data['timezone']] || Time.zone
    duration = duration_for(resource, @args['service_id'], @args['duration_min'])
    settings = window.merge(zone: zone, duration: duration, resource: resource)
    date = window[:from].in_time_zone(zone).to_date
    last_day = window[:to].in_time_zone(zone).to_date
    while date <= last_day && slots.size < window[:limit]
      append_day_slots(slots, date, settings)
      date += 1.day
    end
  end

  def append_day_slots(slots, date, window)
    cursor = window[:zone].local(date.year, date.month, date.day, 9)
    while cursor.hour < 18 && slots.size < window[:limit]
      ending = cursor + window[:duration].minutes
      if slot_inside_window?(cursor, ending, window) && slot_available?(window[:resource], cursor, ending)
        slots << simulated_slot(window[:resource], cursor, ending, window[:duration])
      end
      cursor += 30.minutes
    end
  end

  def slot_inside_window?(starts_at, ends_at, window)
    starts_at >= window[:from] && starts_at >= Time.current && ends_at <= window[:to]
  end

  def simulated_slot(resource, starts_at, ends_at, duration)
    { resource_id: resource['id'], resource_name: resource['name'], starts_at: starts_at.iso8601, ends_at: ends_at.iso8601,
      duration_min: duration, service_id: @args['service_id'], source: 'local', simulated: true }.compact
  end

  def availability_resources
    records = if @args['resource_ids'].present?
                @args['resource_ids'].map { |id| resource!(id) }
              else
                @data['resources'].select { |record| record['active'] }
              end
    return records unless @args['service_id']

    matches = records.select { |record| record['service_ids'].include?(@args['service_id'].to_i) }
    raise ArgumentError, 'Service is not available for these specialists' if matches.empty?

    matches
  end
end
