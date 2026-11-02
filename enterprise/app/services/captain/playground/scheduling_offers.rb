# Server-owned coordinates of slots actually offered by real scheduling reads.
# No patient, credential, cabinet or provider command data enters the session.
require 'digest'

class Captain::Playground::SchedulingOffers
  READS = %w[search_available_slots get_scheduling_resource_availability search_booking_options].freeze
  CHILDREN = %w[slots days next_available results specialists data].freeze
  TTL = 5.minutes

  def initialize(session)
    @session = session
  end

  def record(tool_id, result, arguments)
    return unless READS.include?(tool_id) && @session.read_enabled?
    return if Captain::ToolResult.error?(result)

    payload = result.is_a?(String) ? JSON.parse(result) : result
    generation = @session.permissions['generation']
    store(extract(payload, arguments.to_h.deep_stringify_keys), generation)
  rescue JSON::ParserError, TypeError, ArgumentError, Scheduling::Error
    nil
  end

  def available?(resource_id:, service_id:, starts_at:, ends_at:)
    matching(resource_id, service_id, starts_at).any? { |slot| Time.iso8601(slot['ends_at']) == ends_at }
  end

  def duration_for(resource_id:, service_id:, starts_at:)
    durations = matching(resource_id, service_id, starts_at).map do |slot|
      ((Time.iso8601(slot['ends_at']) - Time.iso8601(slot['starts_at'])) / 60).to_i
    end.uniq
    durations.first if durations.one?
  end

  private

  def store(slots, generation)
    bindings = {}
    stamped = slots.filter_map { |slot| stamp(slot, generation, bindings) }
    @session.synchronize_state do
      current = Array(@session.data['catalog_slots']).select { |slot| slot['expires_at'] > Time.current.to_i }
      @session.data['catalog_slots'] = (stamped + current).uniq { |slot| slot.except('expires_at', 'generation') }.first(100)
    end
  end

  def matching(resource_id, service_id, starts_at)
    generation = @session.permissions['generation']
    binding = binding_for(resource_id, service_id)
    return [] unless binding

    identity = [resource_id, service_id, generation, binding]
    snapshot = @session.synchronize_state { Array(@session.data['catalog_slots']).map(&:dup) }
    snapshot.select do |slot|
      slot['expires_at'] > Time.current.to_i && slot.values_at('resource_id', 'service_id', 'generation', 'binding') == identity &&
        Time.iso8601(slot['starts_at']) == starts_at
    end
  end

  def stamp(slot, generation, bindings)
    key = slot.values_at('resource_id', 'service_id')
    binding = bindings[key] ||= binding_for(*key)
    slot.merge('expires_at' => TTL.from_now.to_i, 'generation' => generation, 'binding' => binding) if binding
  end

  def binding_for(resource_id, service_id)
    resource = @session.account.scheduling_resources.available_for_scheduling.find_by(id: resource_id)
    return unless resource

    service = @session.account.scheduling_services.active.find_by(id: service_id) if service_id
    hook = @session.account.hooks.enabled.find_by(app_id: 'medelement')
    Digest::SHA256.hexdigest(JSON.generate([
      @session.account.id, resource.attributes.slice('id', 'updated_at', 'timezone', 'custom_attributes'),
      service&.attributes&.slice('id', 'updated_at', 'duration_min', 'custom_attributes'),
      hook_identity(hook)
    ].as_json))
  end

  def hook_identity(hook)
    return unless hook

    configuration = Integrations::Medelement::Configuration.new(hook: hook)
    [hook.id, hook.status, hook.updated_at, configuration.organization_id, configuration.company_login, configuration.time_zone]
  end

  def extract(value, inherited, depth = 0)
    return [] if depth > 12
    return value.first(100).flat_map { |child| extract(child, inherited, depth + 1) } if value.is_a?(Array)
    return [] unless value.is_a?(Hash)

    value = value.deep_stringify_keys
    context = coordinates(value, inherited)
    own = raw_slot(value, context) + compact_slots(value, context)
    own + value.slice(*CHILDREN).values.flat_map { |child| extract(child, context, depth + 1) }
  end

  def coordinates(value, inherited)
    context = inherited.merge(value.slice('resource_id', 'service_id', 'duration_min'))
    context['resource_id'] = value['resource']['id'] if value['resource'].is_a?(Hash)
    context['service_id'] = value['service']['id'] if value['service'].is_a?(Hash)
    context['service_id'] = value['slots_service_id'] if value.key?('slots_service_id')
    context
  end

  def raw_slot(value, context)
    return [] unless value['starts_at'].present? && value['ends_at'].present?
    return [] if value['status'].present? && value['status'] != 'available'

    slot_entry(context, Time.iso8601(value['starts_at']), Time.iso8601(value['ends_at']))
  end

  def compact_slots(value, context)
    duration = Integer(context['duration_min'], exception: false)
    return [] unless compact_day?(value, duration)

    resource = @session.account.scheduling_resources.available_for_scheduling.find_by(id: context['resource_id'])
    return [] unless resource

    date = Date.iso8601(value['date'])
    value['times'].first(10).flat_map { |clock| compact_slot(context, resource, date, clock, duration) }
  end

  def compact_day?(value, duration)
    value['date'].present? && value['times'].is_a?(Array) &&
      duration&.between?(Scheduling::Constants::MIN_DURATION_MINUTES, Scheduling::Constants::MAX_DURATION_MINUTES)
  end

  def compact_slot(context, resource, date, clock, duration)
    return [] unless clock.is_a?(String) && clock.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

    parser = Captain::Tools::Agent::AppointmentTimeInput
    zone = parser.timezone(resource_timezone: resource.timezone, account_timezone: @session.account.reporting_timezone)
    starts_at = parser.parse("#{date.iso8601}T#{clock}", timezone: zone, field_name: 'starts_at')
    slot_entry(context, starts_at, starts_at + duration.minutes)
  end

  def slot_entry(context, starts_at, ends_at)
    return [] unless context['resource_id'].to_i.positive? && ends_at > starts_at

    [context.slice('resource_id', 'service_id').compact.transform_values(&:to_i).merge(
      'starts_at' => starts_at.iso8601, 'ends_at' => ends_at.iso8601
    )]
  end
end
