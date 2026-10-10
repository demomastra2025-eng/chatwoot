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
    unless duration.between?(Scheduling::Constants::MIN_DURATION_MINUTES, Scheduling::Constants::MAX_DURATION_MINUTES)
      raise ArgumentError, 'Duration is outside the supported scheduling range'
    end

    duration
  end

  def slot_available?(resource, starts_at, ends_at, exclude_id: nil)
    availability_service(resource, from: starts_at, to: ends_at, exclude_id: exclude_id).available?(starts_at: starts_at, ends_at: ends_at)
  end

  def availability_service(resource, from:, to:, exclude_id: nil)
    Captain::Playground::AvailabilitySnapshot.build(resource: resource, appointments: @data['appointments'], from: from, to: to,
                                                   ignore_appointment_id: exclude_id)
  end

  def available_slots
    from = parse_time(@args.fetch('from'))
    to = parse_time(@args.fetch('to'))
    Scheduling::AvailableSlotSearchService.new(
      account: @session.account, from: from, to: to, snapshots: scheduling_snapshots,
      **@args.slice('resource_ids', 'service_id', 'duration_min', 'limit').symbolize_keys
    ).perform.merge(simulated: true)
  end

  def resource_schedule
    scheduling_snapshots.schedule(resource_id: @args.fetch('resource_id'), from: parse_time(@args.fetch('from')), to: parse_time(@args.fetch('to')),
                                  **@args.slice('include_breaks', 'include_holidays', 'include_time_offs').symbolize_keys).merge(simulated: true)
  end

  def resource_availability
    resource = scheduling_snapshots.resources.find { |item| item.id == @args.fetch('resource_id') }
    raise ArgumentError, 'Record is not available' unless resource

    service = scheduling_snapshots.service(@args['service_id'])
    if service && !scheduling_snapshots.linked_resource_ids(service.id).include?(resource.id)
      raise ArgumentError, 'No recorded service-price link for this resource; provider eligibility is unverified'
    end
    scheduling_snapshots.availability(resource: resource, from: parse_time(@args.fetch('from')), to: parse_time(@args.fetch('to')), service: service,
                                     **@args.slice('duration_min', 'limit').symbolize_keys).merge(
                                       simulated: true, availability_source: 'local_rules', provider_checked: false, provider_required: false,
                                       service_link_status: service ? 'local_configured' : 'not_requested'
                                     )
  end

  def scheduling_snapshots
    @scheduling_snapshots ||= Captain::Playground::SchedulingSnapshots.new(@data)
  end
end
