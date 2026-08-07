class Integrations::Medelement::ProviderCommands::PatientActionsService
  TOKEN_PATTERN = /\A[0-9a-f]{64}\z/

  def initialize(command:, actor:)
    @command = command
    @actor = actor
  end

  def candidates
    require_status!('awaiting_patient_selection')
    patient_resolver.candidate_options
  end

  def select!(token:)
    token = token.to_s
    raise invalid_action('patient_candidate_invalid') unless TOKEN_PATTERN.match?(token)
    raise invalid_action('patient_candidate_invalid') unless candidates.any? { |candidate| secure_match?(candidate[:token], token) }

    resume!(
      expected_status: 'awaiting_patient_selection',
      state: { 'selected_patient_token' => token }
    )
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

  private

  attr_reader :actor, :command

  def patient_resolver
    @patient_resolver ||= Integrations::Medelement::ProviderCommands::PatientResolver.new(
      command: command,
      client: Integrations::Medelement::Client.new(
        configuration: Integrations::Medelement::Configuration.new(hook: command.hook)
      )
    )
  end

  def resume!(expected_status:, state:)
    resumed = false
    command.with_lock do
      command.reload
      require_status!(expected_status)
      command.update!(
        status: command.status_for_transition('queued'),
        last_error_code: nil,
        last_error_status: nil,
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

  def secure_match?(first, second)
    first.bytesize == second.bytesize && ActiveSupport::SecurityUtils.secure_compare(first, second)
  end

  def invalid_action(code)
    Scheduling::Error.new(code: code, message: 'Patient action is not available', status: :conflict)
  end
end
