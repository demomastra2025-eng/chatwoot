module Captain::Playground::SlotCalendar
  private

  def append_resource_slots(slots, resource, window)
    duration = duration_for(resource, @args['service_id'], @args['duration_min'])
    availability_service(resource, from: window[:from], to: window[:to]).slots(duration_min: duration).each do |slot|
      next if Time.iso8601(slot[:starts_at]) < Time.current
      break if slots.size >= window[:limit]

      slots << slot.merge(resource_name: resource['name'], duration_min: duration, service_id: @args['service_id'],
                         source: 'local', simulated: true).compact
    end
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
