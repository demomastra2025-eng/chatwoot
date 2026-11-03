# Server-owned coordinates of slots actually offered by real scheduling reads.
# No patient, credential, cabinet or provider command data enters the session.
class Captain::Playground::SchedulingOffers
  READS = %w[search_available_slots get_scheduling_resource_availability search_booking_options].freeze
  CHILDREN = %w[slots days next_available results specialists data].freeze
  TTL = 5.minutes

  def initialize(session)
    @session = session
  end

  def begin_read(tool_id, arguments)
    return unless READS.include?(tool_id) && @session.read_enabled?

    Captain::Playground::SchedulingReadSnapshot.for_arguments(@session, arguments)
  rescue Scheduling::Error, ArgumentError, TypeError
    nil # The production delegate still owns validation and its error contract.
  end

  def record(tool_id, result, arguments, provenance:)
    return unless valid_origin?(tool_id, provenance)
    return if Captain::ToolResult.error?(result)

    payload = result.is_a?(String) ? JSON.parse(result) : result
    slots = extract(payload, arguments.to_h.deep_stringify_keys, provenance)
    return if slots.empty?

    commit_unchanged(slots, provenance)
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

  def valid_origin?(tool_id, provenance)
    READS.include?(tool_id) && provenance&.valid?
  end

  def commit_unchanged(slots, provenance)
    current = current_snapshot(slots)
    return unless current.valid? && provenance.generation == current.generation

    store(slots.filter_map { |slot| stamp(slot, provenance, current) })
  end

  def store(stamped)
    @session.synchronize_state do
      current = Array(@session.data['catalog_slots']).select { |slot| slot['expires_at'] > Time.current.to_i }
      @session.data['catalog_slots'] = (stamped + current).uniq { |slot| slot.except('expires_at', 'generation') }.first(100)
    end
  end

  def matching(resource_id, service_id, starts_at)
    current = current_snapshot([{ 'resource_id' => resource_id, 'service_id' => service_id }])
    binding = current.binding_for(resource_id, service_id)
    return [] unless binding

    identity = [resource_id, service_id, current.generation, binding]
    snapshot = @session.synchronize_state { Array(@session.data['catalog_slots']).map(&:dup) }
    snapshot.select do |slot|
      slot['expires_at'] > Time.current.to_i && slot.values_at('resource_id', 'service_id', 'generation', 'binding') == identity &&
        Time.iso8601(slot['starts_at']) == starts_at
    end
  end

  def stamp(slot, provenance, current)
    key = slot.values_at('resource_id', 'service_id')
    original_binding = provenance.binding_for(*key)
    return unless original_binding && original_binding == current.binding_for(*key)

    slot.merge('expires_at' => TTL.from_now.to_i, 'generation' => provenance.generation, 'binding' => original_binding)
  end

  def current_snapshot(slots)
    Captain::Playground::SchedulingReadSnapshot.for_slots(@session, slots)
  end

  def extract(value, inherited, provenance, depth = 0)
    return [] if depth > 12
    return value.first(100).flat_map { |child| extract(child, inherited, provenance, depth + 1) } if value.is_a?(Array)
    return [] unless value.is_a?(Hash)

    value = value.deep_stringify_keys
    context = coordinates(value, inherited)
    own = raw_slot(value, context) + compact_slots(value, context, provenance)
    own + value.slice(*CHILDREN).values.flat_map { |child| extract(child, context, provenance, depth + 1) }
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

  def compact_slots(value, context, provenance)
    duration = Integer(context['duration_min'], exception: false)
    return [] unless compact_day?(value, duration)

    timezone = provenance.timezone(context['resource_id'])
    return [] unless timezone

    date = Date.iso8601(value['date'])
    value['times'].first(10).flat_map { |clock| compact_slot(context, timezone, date, clock, duration) }
  end

  def compact_day?(value, duration)
    value['date'].present? && value['times'].is_a?(Array) &&
      duration&.between?(Scheduling::Constants::MIN_DURATION_MINUTES, Scheduling::Constants::MAX_DURATION_MINUTES)
  end

  def compact_slot(context, timezone, date, clock, duration)
    return [] unless clock.is_a?(String) && clock.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

    parser = Captain::Tools::Agent::AppointmentTimeInput
    zone = parser.timezone(resource_timezone: timezone, account_timezone: @session.account.reporting_timezone)
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
