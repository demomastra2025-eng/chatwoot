# A session-owned projection of real catalogue IDs into the synthetic namespace.
# Only catalogue fields and offered slot coordinates are retained, never patients
# or provider credentials. A projection cannot be used by RealToolExecutor.
class Captain::Playground::SimulationCatalog
  def initialize(session)
    @session = session
    @scenario = session.scenario
    @bindings = session.data['catalog_bindings'] ||= { 'resources' => {}, 'services' => {} }
    @offers = Captain::Playground::SchedulingOffers.new(session)
  end

  def arguments(arguments, tool_id:)
    result = arguments.to_h.deep_stringify_keys
    return result unless @session.read_enabled?

    authorize_operator!(tool_id)
    import_arguments!(result)
    decoded = @session.namespace.decode(result)
    bind_appointment!(decoded)
    infer_duration!(result, decoded) if tool_id == 'create_appointment'
    result
  end

  def available?(local_resource_id:, local_service_id:, starts_at:, ends_at:, exclude_id: nil)
    real_id = real_id_for('resources', local_resource_id)
    return nil unless real_id

    raise ArgumentError, 'Reading real data is disabled' unless @session.read_enabled?

    resource = @session.account.scheduling_resources.available_for_scheduling.find(real_id)
    service = resolve_service(resource, local_service_id)
    return false if synthetic_conflict?(local_resource_id, starts_at, ends_at, exclude_id)

    options = provider_options(resource, service, starts_at, ends_at)
    return false if options.nil?

    current_slot_available?(resource, service, starts_at, ends_at, **options)
  end

  private

  def import_arguments!(result)
    { 'resource_id' => 'resources', 'service_id' => 'services' }.each do |key, collection|
      next unless result[key].to_s.match?(/\A[1-9]\d*\z/)

      local_id = import(collection, result[key].to_i)
      result[key] = @session.namespace.encode({ id: local_id })[:id]
    end
  end

  def bind_appointment!(decoded)
    resource_id, service_id = appointment_references(decoded)
    real_resource = real_id_for('resources', resource_id)
    if real_resource
      import('resources', real_resource)
      import('services', real_id_for('services', service_id)) if real_id_for('services', service_id)
      resolve_service(@session.account.scheduling_resources.available_for_scheduling.find(real_resource), service_id)
    elsif real_id_for('services', service_id)
      raise ArgumentError, 'Real and synthetic catalogue references cannot be mixed'
    end
  end

  def current_slot_available?(resource, service, starts_at, ends_at, **)
    payload = Scheduling::ResourceAvailabilityQueryService.new(
      resource: resource, service: service, from: starts_at, to: ends_at,
      duration_min: ((ends_at - starts_at) / 60).to_i, **
    ).perform
    payload[:slots].any? { |slot| Time.iso8601(slot[:starts_at]) == starts_at && Time.iso8601(slot[:ends_at]) == ends_at }
  end

  def provider_options(resource, service, starts_at, ends_at)
    return {} unless Scheduling::AvailableSlotSearchService.provider_related?(resource)
    return unless Scheduling::ResourceHoursPolicy.new(resource: resource).provider_hours?
    return unless @offers.available?(resource_id: resource.id, service_id: service&.id, starts_at: starts_at, ends_at: ends_at)

    { provider_working_windows: [[starts_at, ends_at]], replace_work_rules: true }
  end

  def infer_duration!(arguments, decoded)
    return unless duration_missing?(arguments)

    real_id = real_id_for('resources', decoded['resource_id'])
    return unless real_id

    resource = @session.account.scheduling_resources.available_for_scheduling.find(real_id)
    service = real_service(decoded['service_id'])
    parser = Captain::Tools::Agent::AppointmentTimeInput
    zone = parser.timezone(resource_timezone: resource.timezone, account_timezone: @session.account.reporting_timezone)
    starts_at = parser.parse(arguments['starts_at'], timezone: zone, field_name: 'starts_at')
    duration = @offers.duration_for(resource_id: resource.id, service_id: service&.id, starts_at: starts_at)
    arguments['duration_min'] =
      duration || Scheduling::ResourceAvailabilityQueryService.duration_for(resource: resource, service: service, duration_min: nil)
  end

  def appointment_references(decoded)
    appointment = @scenario.data['appointments'].find { |item| item['id'] == decoded['appointment_id'] }.to_h
    [decoded['resource_id'] || appointment['resource_id'], decoded['service_id'] || appointment['service_id']]
  end

  def duration_missing?(arguments)
    arguments['duration_min'].blank? && arguments['ends_at'].blank? && arguments['starts_at'].present?
  end

  def real_service(local_id)
    real_id = real_id_for('services', local_id)
    @session.account.scheduling_services.active.find(real_id) if real_id
  end

  def authorize_operator!(tool_id)
    definition = Captain::ToolRegistry.definition_for(tool_id)
    allowed = Captain::ToolPolicy.execution_allowed?(
      definition.to_h, assistant: @session.assistant, scope_name: Captain::ToolAccess::SCOPE_ASSISTANT, user: @session.user
    )
    raise ArgumentError, 'Tool permission is not available for the current operator' unless allowed
  end

  def real_id_for(collection, local_id)
    @bindings.fetch(collection).key(local_id.to_i)&.to_i
  end

  def import(collection, real_id)
    relation = if collection == 'resources'
                 @session.account.scheduling_resources.available_for_scheduling
               else
                 @session.account.scheduling_services.active
               end
    record = relation.find(real_id)
    local_id = local_id_for!(collection, real_id)
    save_snapshot(collection, local_id, record)
    local_id
  end

  def local_id_for!(collection, real_id)
    existing = @bindings.fetch(collection)[real_id.to_s]
    return existing if existing

    if @scenario.data.fetch(collection).size >= Captain::Playground::Scenario::MAX_RECORDS
      raise ArgumentError, 'The session catalogue is full; reset Playground'
    end

    @bindings.fetch(collection)[real_id.to_s] = @scenario.next_id!
  end

  def save_snapshot(collection, local_id, record)
    fields = catalogue_fields(record, collection)
    existing = @scenario.data.fetch(collection).find { |item| item['id'] == local_id }
    # Historical simulated appointments retain their snapshot links. Eligibility
    # of the requested action is checked against the live link in resolve_service.
    fields['service_ids'] = existing['service_ids'] if existing && collection == 'resources'
    existing ? existing.merge!(fields) : @scenario.data.fetch(collection).push(fields.merge('id' => local_id))
  end

  def catalogue_fields(record, collection)
    return record.attributes.slice('name', 'active', 'duration_min').merge('amount' => record.base_price) if collection == 'services'

    record.attributes.slice('name', 'timezone', 'active', 'specialty', 'slot_duration_min').merge(
      'service_ids' => [], 'work_rules' => rules(record.work_rules), 'break_rules' => rules(record.break_rules)
    )
  end

  def rules(relation)
    relation.active.map { |rule| rule.attributes.slice('weekday', 'start_minute', 'end_minute') }
  end

  def resolve_service(resource, local_id)
    return if local_id.blank?

    real_id = real_id_for('services', local_id)
    raise ArgumentError, 'A real specialist requires a service from the same real catalogue' unless real_id

    service = @session.account.scheduling_services.active.find(real_id)
    raise ArgumentError, 'Service is not available for this specialist' unless resource.service_prices.active.exists?(service_id: service.id)

    snapshot = @scenario.data.fetch('resources').find { |item| item['id'] == @bindings['resources'][resource.id.to_s] }
    snapshot['service_ids'] |= [local_id.to_i]
    service
  end

  def synthetic_conflict?(local_id, starts_at, ends_at, exclude_id)
    @scenario.data.fetch('appointments').any? do |item|
      item['resource_id'] == local_id && item['id'] != exclude_id && item['status'] != 'cancelled' &&
        Time.iso8601(item['starts_at']) < ends_at && starts_at < Time.iso8601(item['ends_at'])
    end
  end
end
