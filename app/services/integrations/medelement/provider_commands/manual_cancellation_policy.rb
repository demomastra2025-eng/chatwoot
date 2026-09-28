class Integrations::Medelement::ProviderCommands::ManualCancellationPolicy
  class << self
    def reception_codes(command)
      state = command.execution_state.to_h
      values = [state['write_provider_reception_code'], command.provider_reception_code,
                *Array(state['cancelled_reception_candidate_codes'])]
      values.filter_map { |value| value.to_s.strip.presence }.uniq
    end

    def available?(command)
      codes = reception_codes(command)
      command.create_reception? && command.reconcilable? && command.appointment_id.present? &&
        command.execution_state.to_h['write_phase'] == 'reception_create' && codes.one? &&
        Integrations::Medelement::ProviderCommands::ReceptionVerifier.valid_reception_code?(codes.first) && patient_codes(command).one?
    end

    def patient_codes(command)
      values = [command.execution_state.to_h['write_provider_patient_code'],
                command.request_snapshot['provider_patient_code'], command.provider_patient_code]
      values.filter_map { |value| value.to_s.presence }.uniq
    end
  end

  def initialize(command:)
    @command = command
  end

  # The caller holds the command lock; the discovery guard locks its appointment.
  def validate!
    raise unavailable unless self.class.available?(command) && confirmed_snapshot?
    raise unavailable unless current_booking? && current_binding? && current_scope?

    configuration
  rescue KeyError, ArgumentError
    raise unavailable
  end

  def unavailable
    Scheduling::Error.new(
      code: 'MEDELEMENT_CANCELLATION_RESOLUTION_UNAVAILABLE',
      message: 'The original reception and local appointment must be verified before resolving cancellation',
      status: :conflict
    )
  end

  def resolved_target?
    return false if command.appointment.blank?

    guard = Integrations::Medelement::ProviderCommands::ReceptionDiscoveryGuard.new(command: command)
    guard.current_cancelled_booking?(allow_completed: true) && confirmed_snapshot? && current_binding? &&
      Integrations::Medelement::AppointmentProviderStatus.bound_to_command?(command.appointment, command)
  end

  private

  attr_reader :command

  def confirmed_snapshot?
    command.confirmation_request&.confirmed? && command.confirmation_matches_request_snapshot? && command.request_snapshot_valid?
  end

  def current_booking?
    guard = Integrations::Medelement::ProviderCommands::ReceptionDiscoveryGuard.new(command: command)
    guard.current_booking? || guard.current_cancelled_booking?
  end

  def current_binding?
    appointment = command.appointment
    attributes = appointment.custom_attributes.to_h
    status = Integrations::Medelement::AppointmentProviderStatus
    binding_matches = status::COMMAND_BINDING_KEYS.all? { |key| attributes[key].blank? } || status.bound_to_command?(appointment, command)
    binding_matches && appointment.conversation_id == command.request_snapshot['conversation_id'] &&
      !Integrations::Medelement::ProviderCommand.where(account_id: command.account_id, appointment_id: command.appointment_id)
                                                .exists?(['id > ?', command.id])
  end

  def current_scope?
    current_hook? && current_reception_scope? && current_patient?
  end

  def current_hook?
    snapshot = command.request_snapshot
    command.hook&.medelement? && command.hook.account_id == command.account_id &&
      snapshot['organization_id'].present? && snapshot['organization_id'].to_s == configuration.organization_id.to_s
  end

  def current_reception_scope?
    snapshot = command.request_snapshot
    snapshot.dig('reception', 'time_zone') == configuration.time_zone &&
      command.appointment.resource.custom_attributes.to_h['medelement_specialist_code'].to_s ==
        snapshot.dig('reception', 'specialist_code').to_s
  end

  def current_patient?
    reference = Integrations::Medelement::AppointmentPatientIdentity.provider_code(appointment: command.appointment, contact: command.contact)
    reference.blank? || self.class.patient_codes(command) == [reference.to_s]
  end

  def configuration
    @configuration ||= Integrations::Medelement::Configuration.new(hook: command.hook)
  end
end
