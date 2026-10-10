# Imported receptions keep provider-owned fields. Captain and Copilot may only
# request a move or cancellation through the ordinary confirmed command flow.
class Scheduling::Appointments::ImportedProviderMutationService
  OPERATIONS = %w[move_reception remove_reception].freeze
  TIME_KEYS = %i[starts_at ends_at duration_min].freeze
  SOURCE_SNAPSHOT_KEY = 'imported_appointment_source_snapshot'.freeze

  def self.current_source?(command)
    state = command.execution_state.to_h
    return true unless state.key?(SOURCE_SNAPSHOT_KEY)

    command.appointment.present? && source_snapshot(command.appointment) == state[SOURCE_SNAPSHOT_KEY]
  end

  def self.source_snapshot(appointment)
    {
      'appointment' => Integrations::Medelement::OutboundChangeService.appointment_event_snapshot(appointment).as_json,
      'relationships' => appointment.attributes.slice('account_id', 'contact_id', 'conversation_id', 'crm_deal_id'),
      'source' => appointment.source,
      'updated_at' => appointment.updated_at.utc.iso8601(6),
      'resource_updated_at' => appointment.resource.updated_at.utc.iso8601(6)
    }
  end

  def initialize(appointment:, actor:, operation:, appointment_access:, params: {})
    @appointment = appointment
    @actor = actor
    @operation = operation.to_s
    @appointment_access = appointment_access
    @params = params.to_h.deep_symbolize_keys
  end

  def perform
    validate_request!
    @source_snapshot = source_snapshot
    prepare_move! if moving?
    command = appointment.with_lock { stage_locked_mutation! }
    return appointment if command.nil?

    Integrations::Medelement::ProviderCommands::AutoConfirmationService.new(command: command).perform
    appointment.reload
    appointment.medelement_provider_command_receipt = command.reload
    appointment
  end

  private

  attr_reader :appointment, :actor, :operation, :params, :appointment_access

  def account = appointment.account
  def moving? = operation == 'move_reception'
  def captain_actor? = defined?(Captain::Assistant) && actor.is_a?(Captain::Assistant)

  def validate_request!
    raise ArgumentError, 'Only a provider move or cancellation can be requested' unless operation.in?(OPERATIONS)
    unavailable! unless authorized_actor?
    ensure_imported!
    permitted = moving? ? TIME_KEYS : []
    if (params.keys - permitted).present? || (moving? && params.empty?)
      raise Scheduling::Error.new(code: 'APPOINTMENT_READ_ONLY', message: 'Only the reception time can be changed', status: :unprocessable_content)
    end
  end

  def authorized_actor?
    return account.users.exists?(id: actor.id) if actor.is_a?(User)

    captain_actor? && actor.account_id == account.id && appointment_access.to_h.symbolize_keys[:token].present?
  end

  def ensure_imported!
    unavailable! unless appointment.persisted? && appointment.source == Scheduling::Appointments::MutationGuard::PROVIDER_SOURCE
  end

  def source_snapshot
    self.class.source_snapshot(appointment)
  end

  def prepare_move!
    writable_hook!
    ensure_resource_available!
    @starts_at = datetime(params.fetch(:starts_at, appointment.starts_at))
    @ends_at = if params.key?(:ends_at)
                 datetime(params[:ends_at])
               else
                 @starts_at + requested_duration.seconds
               end
    validate_duration!
    result = provider_availability
    return if result.status == 'fresh' && result.slots.one? && @provider_windows.present?

    code = result.status == 'fresh' ? 'APPOINTMENT_SLOT_UNAVAILABLE' : 'MEDELEMENT_AVAILABILITY_UNVERIFIED'
    raise Scheduling::Error.new(code: code, message: 'The provider interval is not confirmed', status: :conflict)
  end

  def validate_duration!
    duration = (@ends_at - @starts_at) / 60
    return if duration == duration.to_i && duration.between?(5, 1440) &&
              (!params.key?(:duration_min) || integer_duration == duration)

    raise ArgumentError, 'Reception duration must be a whole number of minutes from 5 to 1440'
  end

  def datetime(value)
    Time.zone.parse(value.to_s) || raise(ArgumentError, 'Reception time is required')
  end

  def integer_duration
    value = Integer(params[:duration_min], exception: false)
    numeric = Float(params[:duration_min], exception: false)
    unless numeric && numeric == value && value&.between?(5, 1440)
      raise ArgumentError, 'Reception duration must be a whole number of minutes from 5 to 1440'
    end

    value
  end

  def requested_duration
    params.key?(:duration_min) ? integer_duration * 60 : appointment.ends_at - appointment.starts_at
  end

  def provider_availability
    Integrations::Medelement::ResourceAvailabilityService.new(
      resource: appointment.resource, from: @starts_at, to: @ends_at, slots: [],
      cabinet_code: cabinet_code, exclude_reception_code: Integrations::Medelement::LocalCancellation.reception_code(appointment),
      candidate_slots: lambda do |windows|
        @provider_windows = windows
        [{ resource_id: appointment.resource_id, starts_at: @starts_at.iso8601, ends_at: @ends_at.iso8601 }]
      end
    ).perform
  end

  def stage_locked_mutation!
    unavailable! unless authorized_actor?
    Scheduling::Appointments::AppointmentAccessGuard.new(appointment: appointment, actor: actor, context: appointment_access).validate!
    ensure_imported!
    appointment.resource.lock!
    unavailable! unless source_snapshot == @source_snapshot
    return nil if !moving? && appointment.status == 'cancelled'

    if !moving? && Integrations::Medelement::LocalCancellation.local_only?(appointment)
      Scheduling::Appointments::ProviderLocalCancellationService.new(appointment: appointment, actor: actor).perform
      return nil
    end
    ensure_confirmed_reference!
    validate_local_interval! if moving?
    create_command!
  end

  def ensure_resource_available!
    return if appointment.resource.active? && !appointment.resource.deleted_from_scheduling?

    raise Scheduling::Error.new(code: 'RESOURCE_NOT_AVAILABLE_FOR_SCHEDULING', message: 'Specialist is not available for scheduling',
                                status: :unprocessable_content)
  end

  def ensure_confirmed_reference!
    return if Scheduling::Appointments::ProviderCancellationPolicy.new(appointment: appointment).confirmed_for_removal?

    raise Scheduling::Error.new(code: 'MEDELEMENT_BOOKING_REQUIRES_VERIFICATION', message: 'Provider reception requires verification',
                                status: :conflict)
  end

  def validate_local_interval!
    ensure_resource_available!
    result = Scheduling::AvailabilityService.new(
      resource: appointment.resource, from: @starts_at, to: @ends_at,
      holidays: [], workday_overrides: [], time_offs: [],
      appointments: account.scheduling_appointments.where(resource_id: appointment.resource_id)
                           .where('starts_at < ? AND ends_at > ?', @ends_at, @starts_at).to_a,
      ignore_appointment_id: appointment.id, provider_working_windows: @provider_windows, replace_work_rules: true
    ).availability_result(starts_at: @starts_at, ends_at: @ends_at)
    return if result.available?

    raise Scheduling::Error.new(code: result.code, message: result.message, status: :conflict)
  end

  def writable_hook!
    hook = account.hooks.enabled.find_by(app_id: 'medelement')
    return hook if hook&.feature_allowed? && Integrations::Medelement::Configuration.new(hook: hook).write_enabled?

    raise Scheduling::Error.new(code: 'MEDELEMENT_WRITE_DISABLED', message: 'Medelement writes are disabled', status: :forbidden)
  end

  def cabinet_code = appointment.custom_attributes.to_h['medelement_cabinet_code'].to_s.presence

  def desired_attributes
    attributes = Integrations::Medelement::OutboundChangeService.appointment_event_snapshot(appointment)
    attributes['custom_attributes'] = Scheduling::Appointments::PlaygroundRunStamp.apply(attributes['custom_attributes'])
    return attributes.merge('status' => 'cancelled') unless moving?

    attributes.merge('starts_at' => @starts_at, 'ends_at' => @ends_at, 'duration_min' => (@ends_at - @starts_at).to_i / 60)
  end

  def create_command!
    command = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account, hook: writable_hook!, appointment: appointment, operation: operation,
      idempotency_key: idempotency_key, company_cabinet_code: cabinet_code,
      actor: actor.is_a?(User) ? actor : nil, actor_descriptor: { type: actor.class.base_class.name, id: actor.id },
      desired_starts_at: @starts_at, desired_ends_at: @ends_at, desired_attributes: desired_attributes
    ).perform
    command.update!(execution_state: command.execution_state.merge(SOURCE_SNAPSHOT_KEY => @source_snapshot))
    command
  end

  def idempotency_key
    fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(
      'source' => @source_snapshot, 'actor' => { 'type' => actor.class.base_class.name, 'id' => actor.id },
      'operation' => operation, 'desired' => desired_attributes.as_json
    )
    "imported-appointment-mutation:#{fingerprint}"
  end

  def unavailable!
    raise Scheduling::Error.new(code: 'APPOINTMENT_ACCESS_CHANGED', message: 'Record is not available', status: :conflict)
  end
end
