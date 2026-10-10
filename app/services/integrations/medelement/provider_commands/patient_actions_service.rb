class Integrations::Medelement::ProviderCommands::PatientActionsService
  TOKEN_PATTERN = /\A[0-9a-f]{64}\z/

  def self.selection_available?(command)
    return true if command.awaiting_patient_selection?

    eligible = command.failed? && command.last_error_code == 'patient_ref_conflict' && command.create_reception? &&
      !command.provider_write_started? && command.request_snapshot_valid? && command.appointment
    return false unless eligible && command.confirmation_request&.confirmed? && command.confirmation_matches_request_snapshot?
    return false unless Integrations::Medelement::AppointmentPatientIdentity.current?(command)

    status = Integrations::Medelement::AppointmentProviderStatus
    command.appointment.custom_attributes.to_h[status::COMMAND_ID_KEY].blank? || status.bound_to_command?(command.appointment, command)
  end

  def initialize(command:, actor:)
    @command = command
    @actor = actor
  end

  def candidates
    require_staff!
    require_selection_available!
    patient_resolver.candidate_options
  rescue Integrations::Medelement::ProviderScope::MismatchError
    raise invalid_action('provider_scope_mismatch')
  end

  def select!(token:)
    token = token.to_s
    raise invalid_action('patient_candidate_invalid') unless TOKEN_PATTERN.match?(token)
    require_staff!
    return command if selection_replayed?(token)

    require_selection_available!
    expected_status = command.logical_status
    expected_fingerprint = command.execution_state.to_h['request_fingerprint']
    patient = patient_resolver.selection_candidate(token: token)
    raise invalid_action('patient_candidate_invalid') unless patient

    resume!(
      expected_status: expected_status,
      state: { 'selected_patient_token' => token }
    ) do
      require_selection_available!
      Integrations::Medelement::ProviderCommands::PatientSelectionService.new(
        command: command, actor: actor, patient: patient, expected_fingerprint: expected_fingerprint
      ).perform
    end
  rescue Integrations::Medelement::ProviderScope::MismatchError
    raise invalid_action('provider_scope_mismatch')
  end

  def confirm_creation!
    require_status!('awaiting_patient_creation')
    action = command.execution_state.to_h['patient_action'].to_h
    raise invalid_action('patient_identity_incomplete') unless action['can_confirm'] == true

    resume!(
      expected_status: 'awaiting_patient_creation',
      state: { 'patient_creation_confirmed' => true }
    )
  end

  def retry_phone_mismatch!
    resume!(
      expected_status: 'awaiting_phone_refresh',
      state: { 'patient_phone_mismatch_accepted' => true }
    )
  end

  private

  attr_reader :actor, :command

  def patient_resolver
    configuration = Integrations::Medelement::Configuration.new(hook: command.hook)
    @patient_resolver ||= Integrations::Medelement::ProviderCommands::PatientResolver.new(
      command: command,
      client: Integrations::Medelement::Client.new(configuration: configuration),
      organization_id: configuration.organization_id
    )
  end

  def resume!(expected_status:, state:)
    resumed = false
    command.with_lock do
      command.reload
      selected_token = state['selected_patient_token']
      next if selected_token && command.logical_status != expected_status && selection_replayed?(selected_token)

      require_status!(expected_status)
      yield if block_given?
      command.update!(
        status: command.status_for_transition('queued'),
        last_error_code: nil,
        last_error_status: nil,
        executed_at: nil,
        execution_state: command.execution_state.to_h.except('patient_action').merge(state).merge(
          'patient_action_resolved_at' => Time.current.iso8601,
          'patient_action_resolved_by_id' => actor.id
        )
      )
      resumed = true
    end
    Integrations::Medelement::ProviderCommandJob.perform_later(command.id) if resumed
    command
  end

  def require_status!(expected_status)
    return if command.logical_status == expected_status

    raise invalid_action('patient_action_not_available')
  end

  def require_selection_available!
    raise invalid_action('patient_action_not_available') unless self.class.selection_available?(command)
  end

  def require_staff!
    return if actor.is_a?(User) && command.account.users.exists?(id: actor.id)

    raise invalid_action('patient_action_not_available')
  end

  def selection_replayed?(token)
    state = command.execution_state.to_h
    return false unless command.logical_status.in?(%w[queued processing succeeded]) && state['patient_selection_previous_confirmation_id'].present?
    return false unless secure_match?(state['selected_patient_token'].to_s, token)

    command.request_snapshot_valid? && command.confirmation_request&.confirmed? &&
      command.confirmation_matches_request_snapshot? && Integrations::Medelement::AppointmentPatientIdentity.current?(command)
  end

  def secure_match?(first, second)
    first.bytesize == second.bytesize && ActiveSupport::SecurityUtils.secure_compare(first, second)
  end

  def invalid_action(code)
    Scheduling::Error.new(code: code, message: 'Patient action is not available', status: :conflict)
  end
end
