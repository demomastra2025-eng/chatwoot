# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ProviderCommands::Executor
  class ClaimLost < StandardError; end
  BOOKABLE_APPOINTMENT_STATUSES = %w[scheduled confirmed].freeze
  RATE_LIMIT_REQUEUE_ATTEMPTS = 5

  def initialize(command:, client: nil)
    @command = command
    @client = client
  end

  def perform
    policy = Outbound::PlaygroundDeliveryPolicy.for_execution(command)
    Outbound::PlaygroundDeliveryPolicy.with(policy) { perform_with_playground_context }
  end

  # The ordered rescue map is the public command outcome contract.
  # rubocop:disable Metrics/MethodLength
  def perform_with_playground_context
    return unless claim!

    validate_execution_gate!
    execute_operation!
  rescue Integrations::Medelement::ProviderCommands::PatientActionRequired => e
    await_patient_action!(e)
  rescue Integrations::Medelement::Client::RateLimitedError => e
    requeue_after_rate_limit!(e)
  rescue Integrations::Medelement::Client::ApiError => e
    # An explicit provider rejection is a failure. Only an ambiguous answer (timeout, 5xx, dropped connection) is read
    # back, and then only a positive match can apply the change.
    fail_command!(
      code: 'provider_http_error', status: e.status, reconciliation: e.ambiguous?,
      failure: { 'provider_message' => e.provider_message }
    )
  rescue Integrations::Medelement::ProviderCommands::ExecutionError => e
    fail_command!(code: e.code, reconciliation: e.reconciliation?)
  rescue Integrations::Medelement::ProviderCommands::RequestSnapshotSchema::DestinationIntervalError => e
    fail_command!(code: e.code, reconciliation: write_started?)
  rescue Integrations::Medelement::ProviderCommands::Preflight::SlotConflict
    fail_command!(code: 'slot_conflict')
  rescue Integrations::Medelement::ProviderCommands::Preflight::SlotUnavailable
    fail_command!(code: 'slot_unavailable')
  rescue Integrations::Medelement::ProviderCommands::Preflight::StateChanged
    fail_command!(code: 'remote_state_changed', reconciliation: true)
  rescue Integrations::Medelement::ProviderScope::MismatchError
    fail_command!(code: 'provider_scope_mismatch', reconciliation: write_started?)
  rescue Integrations::Medelement::ContactFieldResolutionService::FieldAlreadyUsedError => e
    record_contact_field_conflict(e)
    fail_command!(code: 'contact_field_conflict', reconciliation: true)
  rescue ClaimLost
    nil
  rescue StandardError => e
    Rails.logger.error("[MEDELEMENT::PROVIDER_COMMAND] command_id=#{command.id} error=#{e.class}")
    fail_command!(code: 'executor_error', reconciliation: write_started?)
  end
  # rubocop:enable Metrics/MethodLength

  private

  private :perform_with_playground_context

  attr_reader :command

  def record_contact_field_conflict(error)
    Integrations::Medelement::ContactFieldResolutionService.record_provider_command_conflict!(command, error)
  rescue StandardError => e
    Rails.logger.error(
      "MedElement provider command #{command.id} could not persist contact collision: #{e.class}"
    )
  end

  def claim!
    command.with_lock do
      next false unless command.queued?

      command.update!(
        status: command.status_for_transition('processing'),
        attempt_count: command.attempt_count + 1,
        last_error_code: nil,
        last_error_status: nil,
        execution_state: command.execution_state.merge('claim_token' => claim_token)
      )
      true
    end
  end

  def validate_execution_gate!
    policy = Outbound::PlaygroundDeliveryPolicy.for_execution(command)
    unless Outbound::PlaygroundMutationPolicy.allowed_command?(command, policy)
      if write_started?
        raise reconciliation_error('playground_write_requires_verification')
      end
      raise execution_error('playground_confirmation_required', 'A new provider write requires an exact confirmed Playground action')
    end
    # The hook can change after a removal command is queued or confirmed. Reload before evaluating the final write gate.
    command.hook.reload
    if command.operation == 'remove_reception' && !configuration.remove_reception_on_cancel?
      raise execution_error(
        'MEDELEMENT_REMOVAL_DISABLED',
        'Medelement reception removal was turned off before execution'
      )
    end

    confirmation = command.confirmation_request
    raise execution_error('execution_gate_closed', 'Medelement write confirmation or capability is missing') unless execution_gate_open?(confirmation)
    unless command.confirmation_matches_request_snapshot?(confirmation)
      raise execution_error('confirmation_snapshot_invalid', 'Medelement confirmation does not match the request snapshot')
    end

    Integrations::Medelement::ProviderCommands::RequestSnapshotSchema.validate_reception_destination!(command.request_snapshot)
    if command.request_snapshot_valid?
      validate_provider_scope_snapshot!
      return
    end

    raise execution_error('request_snapshot_invalid', 'Medelement confirmed request snapshot is missing or invalid')
  end

  def validate_provider_scope_snapshot!
    return unless command.request_snapshot.key?('organization_id')
    return if command.request_snapshot['organization_id'].to_s == configuration.organization_id.to_s

    raise Integrations::Medelement::ProviderScope::MismatchError,
          'Medelement organization changed after command creation'
  end

  def execution_gate_open?(confirmation)
    command.hook.enabled? && command.hook.feature_allowed? && configuration.write_enabled? && confirmation&.confirmed?
  end

  def execution_error(code, message)
    Integrations::Medelement::ProviderCommands::ExecutionError.new(code: code, message: message)
  end

  def execute_operation!
    case command.operation
    when 'create_patient'
      apply_patient!(allow_create: true)
    when 'update_patient'
      update_patient!
    when 'create_reception'
      create_reception!
    when 'move_reception'
      move_reception!
    when 'remove_reception'
      remove_reception!
    end
  end

  def apply_patient!(allow_create:)
    code = patient_resolver.resolve!(allow_create: allow_create)
    success_applier.patient!(patient_code: code)
  end

  def update_patient!
    payload = command.request_snapshot.fetch('patient').fetch('payload')
    patient_code = payload.fetch('profile_code')
    Integrations::Medelement::ProviderScope.validate_write!(payload, organization_id: configuration.organization_id)
    remote = patient_by_code(patient_code)
    Integrations::Medelement::ProviderScope.validate!(remote, organization_id: payload['company_code'])
    mark_write_phase!('patient_update', provider_patient_code: patient_code)
    client.update_patient(params: payload)
    # The provider answered OK, so the update is final. A slower read cache may keep showing the old card for a while.
    success_applier.patient!(patient_code: patient_code)
  end

  def create_reception!
    raise reconciliation_error('reception_create_requires_verification') if reception_write_started?

    validate_bookable_appointment!
    validate_current_captain_booking!
    patient_code = patient_resolver.resolve!(allow_create: true)
    preflight_result = preflight.perform
    reception_code = create_remote_reception!(patient_code: patient_code, preflight_result: preflight_result)
    # A successful POST with a valid ID is the receipt for this create. Provider reads may lag;
    # verify them in the integration without withholding success or repeating the POST.
    applied = success_applier.reception_created!(reception_code: reception_code, patient_code: patient_code)
    Integrations::Medelement::ProviderCommandReconciliationJob.perform_later(command.id) if applied
  end

  def validate_bookable_appointment!
    appointment = command.appointment&.reload
    return if appointment && BOOKABLE_APPOINTMENT_STATUSES.include?(appointment.status)

    raise execution_error('appointment_unbookable', 'Appointment is no longer bookable')
  end

  def create_remote_reception!(patient_code:, preflight_result:)
    validate_current_captain_booking!
    ensure_reception_create_not_repeated!
    mark_write_phase!('reception_create', preflight_reception_codes: preflight_result.reception_codes, provider_patient_code: patient_code)
    response = client.create_reception(params: reception_payload_builder.create_payload(patient_code: patient_code))
    reception_code = response.is_a?(Hash) ? response['reception_code'].presence || response['RECEPTION_CODE'].presence : nil
    reference_valid = Integrations::Medelement::ProviderCommands::ReceptionVerifier.valid_reception_code?(reception_code)
    raise reconciliation_error('reception_create_missing_ref') unless reference_valid

    reception_code.to_s.tap { |code| record_write_reference!(provider_reception_code: code) }
  end

  def ensure_reception_create_not_repeated!
    appointment = command.appointment&.reload
    attributes = appointment&.custom_attributes.to_h
    linked = appointment&.external_ref.to_s.start_with?('medelement:reception:') ||
             attributes['medelement_reception_code'].present?
    prior_write = reception_write_started?
    return unless linked || prior_write

    raise reconciliation_error('reception_create_requires_verification') if prior_write

    raise execution_error('reception_create_requires_verification', 'Reception create needs read-only verification')
  end

  def reception_write_started?
    command.execution_state.to_h['write_phase'] == 'reception_create' ||
      command.execution_state.to_h['write_provider_reception_code'].present?
  end

  def validate_current_captain_booking!
    return unless command.request_snapshot.dig('actor', 'type') == 'Captain::Assistant' ||
                  patient_identity_fence_required?

    unless command.create_reception?
      return validate_frozen_patient_identity! if patient_identity_fence_required?

      return
    end

    guard = Integrations::Medelement::ProviderCommands::ReceptionDiscoveryGuard.new(command: command)
    return if guard.current_booking?

    raise execution_error('appointment_superseded', 'Local booking changed before the Medelement write')
  end

  def validate_frozen_patient_identity!
    command.appointment.lock!
    return if Integrations::Medelement::AppointmentPatientIdentity.current?(command)

    raise execution_error('appointment_superseded', 'Local patient identity changed before the Medelement write')
  end

  def patient_identity_fence_required?
    policy = Integrations::Medelement::AppointmentPatientIdentity
    policy.frozen?(command.request_snapshot) || policy.marked?(command.appointment&.custom_attributes)
  end

  def move_reception!
    patient_code = patient_resolver.resolve!(allow_create: false)
    preflight_result = preflight.perform
    mark_write_phase!('reception_move', preflight_reception_codes: preflight_result.reception_codes, provider_patient_code: patient_code)
    client.move_reception(params: reception_payload_builder.move_payload(patient_code: patient_code))
    # The provider answered OK, so the move is final and the requested time becomes the appointment time at once.
    # A read of a slower cached server may still show the old time; that is not a rejection and is never awaited.
    success_applier.reception_moved!
  end

  def remove_reception!
    result = preflight.perform
    return success_applier.reception_removed! if removed_reception_matches?(result.remote_reception)

    begin_reception_removal_write!
    client.remove_reception(reception_code: command.request_snapshot.fetch('provider_reception_code'))
    success_applier.reception_removed!
  end

  # Serialize the last capability check and write-phase transition with hook settings saves.
  # Once write_phase is committed the removal is already processing and may finish if the toggle changes.
  def begin_reception_removal_write!
    command.hook.with_lock do
      unless Integrations::Medelement::Configuration.new(hook: command.hook).remove_reception_on_cancel?
        raise execution_error(
          'MEDELEMENT_REMOVAL_DISABLED',
          'Medelement reception removal was turned off before execution'
        )
      end

      mark_write_phase!('reception_remove')
    end
  end

  def patient_resolver
    @patient_resolver ||= Integrations::Medelement::ProviderCommands::PatientResolver.new(
      command: command,
      client: client,
      organization_id: configuration.organization_id,
      before_create: lambda {
        validate_current_captain_booking!
        mark_write_phase!('patient_create')
      }
    )
  end

  def preflight
    @preflight ||= Integrations::Medelement::ProviderCommands::Preflight.new(
      command: command,
      client: client,
      configuration: configuration
    )
  end

  def reception_payload_builder
    @reception_payload_builder ||= Integrations::Medelement::ProviderCommands::ReceptionPayloadBuilder.new(
      command: command,
      configuration: configuration
    )
  end

  def success_applier
    @success_applier ||= Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: command)
  end

  def configuration
    @configuration ||= Integrations::Medelement::Configuration.new(hook: command.hook)
  end

  def client
    @client ||= Integrations::Medelement::Client.new(configuration: configuration, retry_profile: :command)
  end

  def mark_write_phase!(phase, preflight_reception_codes: nil, provider_patient_code: nil)
    with_patient_identity_write_fence do
      validate_current_imported_source!
      policy = Outbound::PlaygroundDeliveryPolicy.for_execution(command)
      unless Outbound::PlaygroundMutationPolicy.allowed_command?(command, policy)
        raise execution_error('playground_confirmation_required', 'Playground approval was revoked before the provider write')
      end
      publish_write_phase!(phase, preflight_reception_codes: preflight_reception_codes, provider_patient_code: provider_patient_code)
    end
  end

  def validate_current_imported_source!
    return unless command.execution_state.to_h.key?('imported_appointment_source_snapshot')
    if defined?(Scheduling::Appointments::ImportedProviderMutationService) &&
       Scheduling::Appointments::ImportedProviderMutationService.respond_to?(:current_source?) &&
       Scheduling::Appointments::ImportedProviderMutationService.current_source?(command)
      return
    end

    raise execution_error('appointment_superseded', 'Imported appointment changed after confirmation')
  end

  def with_patient_identity_write_fence
    return yield unless command.appointment

    command.with_lock do
      command.appointment.with_lock do
        validate_current_captain_booking!
        yield
      end
    end
  end

  def publish_write_phase!(phase, preflight_reception_codes: nil, provider_patient_code: nil)
    state = command.execution_state.merge('write_phase' => phase)
    state['preflight_reception_codes'] = preflight_reception_codes if preflight_reception_codes
    state['write_provider_patient_code'] = provider_patient_code if provider_patient_code
    updated = Integrations::Medelement::ProviderCommand
              .where(id: command.id, status: command.status_for_transition('processing'))
              .where("execution_state ->> 'claim_token' = ?", claim_token)
              # rubocop:disable Rails/SkipsModelValidations
              .update_all(execution_state: state, updated_at: Time.current)
    # rubocop:enable Rails/SkipsModelValidations
    raise ClaimLost unless updated == 1

    command.reload
  end

  def record_write_reference!(provider_reception_code:)
    state = command.execution_state.merge(
      'write_provider_reception_code' => provider_reception_code,
      Integrations::Medelement::ProviderCommands::ReceptionReceiptVerificationService::STATE_KEY => { 'status' => 'pending', 'attempts' => 0 }
    )
    updated = Integrations::Medelement::ProviderCommand
              .where(id: command.id, status: command.status_for_transition('processing'))
              .where("execution_state ->> 'claim_token' = ?", claim_token)
              # rubocop:disable Rails/SkipsModelValidations
              .update_all(
                provider_reception_code: provider_reception_code,
                execution_state: state,
                updated_at: Time.current
              )
    # rubocop:enable Rails/SkipsModelValidations
    raise ClaimLost unless updated == 1

    command.reload
  end

  def patient_by_code(patient_code)
    client.get_patient(patient_code: patient_code)
  rescue Integrations::Medelement::Client::ApiError => e
    patient = indexed_patient_after_write(patient_code)
    return patient if patient.present?

    raise e
  end

  def indexed_patient_after_write(patient_code)
    Array(client.search_patients_by_codes(patient_codes: [patient_code])).find do |patient|
      remote_patient_code = patient['PROFILE_CODE'].presence || patient['PATIENT_CODE'].presence
      remote_patient_code.to_s == patient_code.to_s
    end
  rescue Integrations::Medelement::Client::ApiError
    nil
  end

  def removed_reception_matches?(remote)
    reception_verifier(command.request_snapshot['provider_patient_code']).removed_match?(remote)
  end

  def reception_verifier(patient_code)
    Integrations::Medelement::ProviderCommands::ReceptionVerifier.new(
      command: command,
      provider_patient_code: patient_code
    )
  end

  def write_started?
    command.execution_state.to_h['write_phase'].present?
  end

  def reconciliation_error(code)
    Integrations::Medelement::ProviderCommands::ExecutionError.new(
      code: code,
      message: 'Medelement write result requires reconciliation',
      reconciliation: true
    )
  end

  def fail_command!(code:, status: nil, reconciliation: false, failure: nil)
    reconciliation &&= write_started?
    reconciliation_enqueued = false
    command.with_lock do
      next unless owns_claim?

      command.update!(
        status: reconciliation ? command.status_for_transition('reconciliation_required') : 'failed',
        last_error_code: code,
        last_error_status: status,
        executed_at: Time.current,
        execution_state: execution_state_with_write_failure(code, status, failure)
      )
      project_failed_appointment_status! unless reconciliation || code == 'appointment_superseded'
      project_unresolved_move_status! if reconciliation && command.move_reception?
      reconciliation_enqueued = reconciliation
    end
    Integrations::Medelement::ProviderCommandReconciliationJob.perform_later(command.id) if reconciliation_enqueued
  end

  # A started move write is remembered with its failure: the move state shows the provider's own answer to staff.
  def execution_state_with_write_failure(code, status, failure)
    return command.execution_state unless command.move_reception? && write_started?

    command.execution_state.merge('write_failure' => { 'code' => code, 'status' => status }.merge(failure.to_h).compact)
  end

  def project_failed_appointment_status!
    provider_status = Integrations::Medelement::AppointmentProviderStatus
    if command.create_reception? && command.request_snapshot.dig('actor', 'type') == 'Captain::Assistant'
      provider_status.persist_if_bound!(command.appointment, provider_status::FAILED, command: command)
    elsif command.move_reception?
      provider_status.persist_rejected_move!(command.appointment, command: command)
    else
      provider_status.persist!(command.appointment, provider_status::FAILED)
    end
  end

  # An ambiguous move answer (timeout, 5xx, dropped connection) is not established until a read shows the new time, so
  # the appointment is flagged for reconciliation. A provider-owned appointment is left alone: writing the flag would invalidate the source snapshot the command is
  # applied against, and the reconciliation could then never finish the move.
  def project_unresolved_move_status!
    return if command.frozen_imported_source?

    provider_status = Integrations::Medelement::AppointmentProviderStatus
    provider_status.persist_for_command!(command.appointment, provider_status::UNKNOWN, command: command)
  end

  # The request slot of one request type stayed busy for too long and the request was not sent. A command that has not
  # written anything yet goes back to the queue and starts again in a moment; one that already wrote reads the provider
  # instead (reconciliation) and never repeats a write.
  def requeue_after_rate_limit!(error)
    return fail_command!(code: 'provider_rate_limited', reconciliation: true) if write_started?
    return fail_command!(code: 'provider_rate_limited') if command.attempt_count >= RATE_LIMIT_REQUEUE_ATTEMPTS

    requeued = command.with_lock do
      next false unless owns_claim?

      command.update!(
        status: command.status_for_transition('queued'),
        last_error_code: 'provider_rate_limited',
        execution_state: command.execution_state.to_h.except('claim_token')
      )
      true
    end
    return unless requeued

    delay = (error.retry_after_ms.to_i / 1000.0).clamp(1, 10).seconds
    Integrations::Medelement::ProviderCommandJob.set(wait: delay).perform_later(command.id)
  end

  def await_patient_action!(action)
    command.with_lock do
      next unless owns_claim?

      command.update!(
        status: command.status_for_transition(action.status),
        last_error_code: action.code,
        last_error_status: nil,
        executed_at: nil,
        execution_state: command.execution_state.to_h.except('claim_token').merge(
          'patient_action' => action.metadata.merge('type' => action.status.delete_prefix('awaiting_'))
        )
      )
    end
  end

  def owns_claim?
    command.processing? && command.execution_state.to_h['claim_token'] == claim_token
  end

  def claim_token
    @claim_token ||= SecureRandom.uuid
  end
end
# rubocop:enable Metrics/ClassLength
