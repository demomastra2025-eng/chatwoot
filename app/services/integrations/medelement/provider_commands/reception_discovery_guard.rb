class Integrations::Medelement::ProviderCommands::ReceptionDiscoveryGuard
  def initialize(command:)
    @command = command
  end

  def validate!
    return if current_booking?

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_RECEPTION_COMMAND_STALE_LOCAL',
      message: 'Local appointment changed after the provider write started',
      status: :conflict
    )
  end

  # Call within the owning transaction when projecting a status or confirming
  # the booking; lock! refreshes the appointment before comparing the snapshot.
  def current_booking?(allow_completed: false)
    appointment.lock!
    current_local_target?(allow_completed: allow_completed)
  end

  # A previously cancelled booking can retain a remote candidate for staff,
  # but must not be projected back as a successful local appointment.
  def current_cancelled_booking?(allow_completed: false)
    appointment.lock!
    appointment.status == 'cancelled' && identity_current?(allow_completed: allow_completed) &&
      destination_identity_current? && current_service_codes == requested_service_codes &&
      captain_booking_current?
  rescue KeyError
    false
  end

  private

  attr_reader :command

  def appointment
    command.appointment
  end

  def current_local_target?(allow_completed:)
    identity_current?(allow_completed: allow_completed) && destination_current? &&
      current_service_codes == requested_service_codes && captain_booking_current?
  rescue KeyError
    false
  end

  def captain_booking_current?
    return true unless command.create_reception? && command.request_snapshot.dig('actor', 'type') == 'Captain::Assistant'

    status = Integrations::Medelement::AppointmentProviderStatus
    attributes = appointment.custom_attributes.to_h
    return status.bound_to_command?(appointment, command) if attributes[status::COMMAND_ID_KEY].present?

    attributes[status::ATTRIBUTE_KEY].in?([nil, status::PENDING, status::UNKNOWN]) &&
      appointment.updated_at <= command.created_at
  end

  def identity_current?(allow_completed:)
    return false unless appointment.contact_id == command.contact_id
    return false unless appointment_patient_identity_current?

    reception_reference_current?(allow_completed: allow_completed)
  end

  def reception_reference_current?(allow_completed:)
    reference = appointment.custom_attributes.to_h['medelement_reception_code']
    return true if appointment.external_ref.blank? && reference.blank?
    return false unless allow_completed && command.provider_reception_code.present?

    reference == command.provider_reception_code &&
      appointment.external_ref == "medelement:reception:#{reference}"
  end

  def appointment_patient_identity_current?
    Integrations::Medelement::AppointmentPatientIdentity.current?(command)
  end

  def destination_current?
    bookable? && destination_identity_current?
  end

  def destination_identity_current?
    reception_snapshot = command.request_snapshot.fetch('reception')
    schedule_current?(reception_snapshot) &&
      appointment.custom_attributes.to_h['medelement_cabinet_code'].to_s == command.company_cabinet_code.to_s
  end

  def bookable?
    appointment.status.in?(Integrations::Medelement::ProviderCommands::Executor::BOOKABLE_APPOINTMENT_STATUSES)
  end

  def schedule_current?(reception_snapshot)
    appointment.resource_id == reception_snapshot.fetch('resource_id').to_i &&
      appointment.starts_at == command.desired_starts_at &&
      appointment.ends_at == command.desired_ends_at
  end

  def current_service_codes
    event_snapshot = Integrations::Medelement::OutboundChangeService.appointment_event_snapshot(appointment)
    normalize_codes(event_snapshot[Integrations::Medelement::OutboundChangeService::NOMENCLATURE_CODES_KEY])
  end

  def requested_service_codes
    normalize_codes(
      Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.service_codes(command.request_snapshot)
    )
  end

  def normalize_codes(codes)
    Array(codes).map(&:to_s).uniq.sort
  end
end
