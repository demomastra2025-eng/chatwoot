class Integrations::Medelement::ProviderCommands::ManualCancellationResolutionService
  RESOLUTION_KEY = 'manual_cancellation_resolution'.freeze
  VERIFIED_AT_KEY = 'medelement_manual_cancellation_verified_at'.freeze

  def initialize(command:, actor:, reception_code:, client: nil)
    @command = command
    @actor = actor
    @reception_code = reception_code.to_s.strip
    @client = client
  end

  def perform
    return command if prepare_verification!

    verify_removed_reception!
    finish_verification!
  rescue Integrations::Medelement::Client::ApiError
    raise Scheduling::Error.new(
      code: 'MEDELEMENT_CANCELLATION_CHECK_FAILED', message: 'Medelement cancellation could not be checked', status: :bad_gateway
    )
  rescue Integrations::Medelement::ProviderScope::MismatchError, Integrations::Medelement::ReceptionServiceRows::InvalidSnapshotError
    raise unverified
  end

  private

  attr_reader :command, :actor, :reception_code, :configuration, :request_fingerprint, :provider_patient_code

  def finish_verification!
    command.with_lock do
      command.reload
      require_account_user!
      next command if resolved?

      validate_current_booking!
      validate_verified_snapshot!
      complete_cancellation!
      command
    end
  end

  def validate_verified_snapshot!
    raise policy.unavailable unless command.execution_state.to_h['request_fingerprint'] == request_fingerprint
    raise policy.unavailable unless policy.class.patient_codes(command) == [provider_patient_code]
  end

  def prepare_verification!
    command.with_lock do
      command.reload
      require_account_user!
      next true if resolved?

      validate_current_booking!
      @request_fingerprint = command.execution_state.to_h['request_fingerprint']
      @provider_patient_code = policy.class.patient_codes(command).first

      false
    end
  end

  def require_account_user!
    return if actor.is_a?(User) && command.account.users.exists?(id: actor.id)

    raise Scheduling::Error.new(code: 'FORBIDDEN', message: 'An account employee must request this check', status: :forbidden)
  end

  def policy
    Integrations::Medelement::ProviderCommands::ManualCancellationPolicy.new(command: command)
  end

  def validate_current_booking!
    @configuration = policy.validate!
    raise policy.unavailable unless policy.class.reception_codes(command) == [reception_code]
  end

  def resolved?
    resolution = command.execution_state.to_h[RESOLUTION_KEY].to_h
    command.cancelled? && resolution['result'] == 'removed' && resolution['source'] == 'medelement_readback' &&
      resolution['reception_code'] == reception_code && resolution['request_fingerprint'] == command.execution_state['request_fingerprint'] &&
      policy.resolved_target?
  end

  def verify_removed_reception!
    client = @client || Integrations::Medelement::Client.new(configuration: configuration)
    reception = client.get_reception(reception_code: reception_code, version: :v2)
    Integrations::Medelement::ProviderScope.validate_write!(reception, organization_id: configuration.organization_id)
    verifier = Integrations::Medelement::ProviderCommands::ReceptionVerifier.new(
      command: command, provider_patient_code: provider_patient_code
    )
    raise unverified unless verifier.removed_destination_match?(reception, expected_reception_code: reception_code)
  end

  def unverified
    Scheduling::Error.new(
      code: 'MEDELEMENT_CANCELLATION_NOT_VERIFIED', message: 'Removal of the exact Medelement reception is not verified', status: :conflict
    )
  end

  def complete_cancellation!
    now = Time.current
    cancel_appointment!(now)
    lifecycle = Integrations::Medelement::ProviderCommands::ReconciliationLifecycle
    state = command.execution_state.to_h.except(lifecycle::CLAIM_TOKEN_KEY, lifecycle::CLAIMED_AT_KEY,
                                                lifecycle::DISPATCH_RESERVED_AT_KEY, 'reconciliation_next_at')
    command.update!(
      status: 'cancelled', executed_at: now, provider_reception_code: reception_code,
      last_error_code: 'reception_cancelled_manually_verified', last_error_status: nil,
      execution_state: state.merge(RESOLUTION_KEY => resolution_audit(now))
    )
  end

  def resolution_audit(now)
    {
      'result' => 'removed', 'source' => 'medelement_readback', 'reception_code' => reception_code,
      'provider_patient_code' => provider_patient_code, 'verified_at' => now.iso8601,
      'verified_by_id' => actor.id, 'request_fingerprint' => request_fingerprint
    }
  end

  def cancel_appointment!(now)
    appointment = command.appointment
    status = Integrations::Medelement::AppointmentProviderStatus
    attributes = appointment.custom_attributes.to_h.except(status::ATTRIBUTE_KEY).merge(
      status::COMMAND_ID_KEY => command.id,
      status::COMMAND_IDEMPOTENCY_KEY => command.idempotency_key,
      status::COMMAND_FINGERPRINT_KEY => command.execution_state['request_fingerprint'],
      status::COMMAND_DISPATCH_IDENTITY_KEY => command.execution_state['dispatch_identity'],
      'medelement_reception_code' => reception_code,
      Integrations::Medelement::AppointmentSnapshotGuard::LOCAL_CANCELLATION_ATTRIBUTE => now.iso8601,
      VERIFIED_AT_KEY => now.iso8601
    )
    appointment.mark_medelement_provider_reconciled!
    appointment.update!(status: 'cancelled', payment_status: 'cancelled',
                        external_ref: "medelement:reception:#{reception_code}", custom_attributes: attributes)
  end
end
