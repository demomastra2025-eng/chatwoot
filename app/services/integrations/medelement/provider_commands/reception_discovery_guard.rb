class Integrations::Medelement::ProviderCommands::ReceptionDiscoveryGuard
  def initialize(command:)
    @command = command
  end

  def validate!
    appointment.lock!
    return if current_local_target?

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_RECEPTION_COMMAND_STALE_LOCAL',
      message: 'Local appointment changed after the provider write started',
      status: :conflict
    )
  end

  private

  attr_reader :command

  def appointment
    command.appointment
  end

  def current_local_target?
    identity_current? && destination_current? && current_service_codes == requested_service_codes
  rescue KeyError
    false
  end

  def identity_current?
    appointment.contact_id == command.contact_id &&
      appointment.external_ref.blank? &&
      appointment.custom_attributes.to_h['medelement_reception_code'].blank?
  end

  def destination_current?
    reception_snapshot = command.request_snapshot.fetch('reception')
    bookable? &&
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
