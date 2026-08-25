# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ProviderCommands::Executor
  class ClaimLost < StandardError; end
  READBACK_DELAYS = [0, 0.25, 0.5, 1, 2, 4, 4].freeze
  BOOKABLE_APPOINTMENT_STATUSES = %w[scheduled confirmed].freeze
  PATIENT_WRITE_RESPONSE_KEYS = Integrations::Medelement::ProviderCommands::PatientResolver::WRITE_RESPONSE_KEYS

  def initialize(command:, client: nil)
    @command = command
    @client = client
  end

  # The ordered rescue map is the public command outcome contract.
  # rubocop:disable Metrics/MethodLength
  def perform
    return unless claim!

    validate_execution_gate!
    execute_operation!
  rescue Integrations::Medelement::ProviderCommands::PatientActionRequired => e
    await_patient_action!(e)
  rescue Integrations::Medelement::Client::ApiError => e
    fail_command!(code: 'provider_http_error', status: e.status, reconciliation: e.ambiguous?)
  rescue Integrations::Medelement::ProviderCommands::ExecutionError => e
    fail_command!(code: e.code, reconciliation: e.reconciliation?)
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
    confirmation = command.confirmation_request
    raise execution_error('execution_gate_closed', 'Medelement write confirmation or capability is missing') unless execution_gate_open?(confirmation)
    unless command.confirmation_matches_request_snapshot?(confirmation)
      raise execution_error('confirmation_snapshot_invalid', 'Medelement confirmation does not match the request snapshot')
    end

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
    response = client.update_patient(params: payload)
    remote = updated_patient_readback(response, patient_code)
    raise reconciliation_error('patient_update_pending_materialization') unless patient_snapshot_matches?(remote)

    success_applier.patient!(patient_code: patient_code)
  end

  def create_reception!
    validate_bookable_appointment!
    patient_code = patient_resolver.resolve!(allow_create: true)
    preflight_result = preflight.perform
    reception_code = create_remote_reception!(patient_code: patient_code, preflight_result: preflight_result)
    remote = bounded_readback do
      candidate = read_reception_after_write(reception_code)
      candidate = merged_destination_readback(candidate, reception_code) unless created_reception_matches?(candidate, patient_code)
      candidate if created_reception_matches?(candidate, patient_code)
    end
    raise reconciliation_error('reception_create_pending_materialization') unless remote

    success_applier.reception_created!(reception_code: reception_code, patient_code: patient_code)
  end

  def validate_bookable_appointment!
    appointment = command.appointment&.reload
    return if appointment && BOOKABLE_APPOINTMENT_STATUSES.include?(appointment.status)

    raise execution_error('appointment_unbookable', 'Appointment is no longer bookable')
  end

  def create_remote_reception!(patient_code:, preflight_result:)
    mark_write_phase!('reception_create', preflight_reception_codes: preflight_result.reception_codes, provider_patient_code: patient_code)
    response = client.create_reception(params: reception_payload_builder.create_payload(patient_code: patient_code))
    reception_code = response.is_a?(Hash) ? response['reception_code'].presence || response['RECEPTION_CODE'].presence : nil
    raise reconciliation_error('reception_create_missing_ref') if reception_code.blank?

    reception_code.to_s.tap { |code| record_write_reference!(provider_reception_code: code) }
  end

  def move_reception!
    patient_code = patient_resolver.resolve!(allow_create: false)
    preflight_result = preflight.perform
    mark_write_phase!('reception_move', preflight_reception_codes: preflight_result.reception_codes, provider_patient_code: patient_code)
    client.move_reception(params: reception_payload_builder.move_payload(patient_code: patient_code))
    remote = bounded_readback do
      candidate = read_reception_after_write(command.request_snapshot.fetch('provider_reception_code'))
      candidate = preflight_result.remote_reception.to_h.merge(candidate.to_h)
      candidate if moved_reception_matches?(candidate, patient_code)
    end
    raise reconciliation_error('reception_move_pending_materialization') unless remote

    success_applier.reception_moved!
  end

  def remove_reception!
    result = preflight.perform
    return success_applier.reception_removed! if removed_reception_matches?(result.remote_reception)

    mark_write_phase!('reception_remove')
    client.remove_reception(reception_code: command.request_snapshot.fetch('provider_reception_code'))
    remote = await_removed_reception(result)
    raise reconciliation_error('reception_remove_pending_materialization') unless remote

    success_applier.reception_removed!
  end

  def patient_resolver
    @patient_resolver ||= Integrations::Medelement::ProviderCommands::PatientResolver.new(
      command: command,
      client: client,
      organization_id: configuration.organization_id,
      before_create: -> { mark_write_phase!('patient_create') }
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
    @client ||= Integrations::Medelement::Client.new(configuration: configuration)
  end

  def mark_write_phase!(phase, preflight_reception_codes: nil, provider_patient_code: nil)
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
    state = command.execution_state.merge('write_provider_reception_code' => provider_reception_code)
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

  def read_reception_after_write(reception_code, version: :v2)
    client.get_reception(reception_code: reception_code, version: version)
  rescue Integrations::Medelement::Client::ApiError
    nil
  end

  def merged_destination_readback(detail, reception_code)
    scoped = destination_receptions_after_write.find do |candidate|
      candidate['RECEPTION_CODE'].to_s == reception_code.to_s
    end
    scoped&.merge(detail.to_h) || detail
  end

  def destination_receptions_after_write
    snapshot = command.request_snapshot.fetch('reception')
    range_start, range_end = destination_calendar_bounds(snapshot)

    client.get_receptions(
      company_cabinet_code: command.request_snapshot.fetch('company_cabinet_code'),
      specialist_code: snapshot.fetch('specialist_code'),
      begin_datetime: range_start.strftime('%d.%m.%Y %H:%M:%S'),
      end_datetime: range_end.strftime('%d.%m.%Y %H:%M:%S')
    )
  rescue Integrations::Medelement::Client::ApiError
    []
  end

  def destination_calendar_bounds(snapshot)
    zone = ActiveSupport::TimeZone[snapshot.fetch('time_zone')]
    starts_on = Time.iso8601(snapshot.fetch('destination_starts_at')).in_time_zone(zone).to_date
    exclusive_end = Time.iso8601(snapshot.fetch('destination_ends_at')).in_time_zone(zone).to_date + 1.day
    [zone.local(starts_on.year, starts_on.month, starts_on.day),
     zone.local(exclusive_end.year, exclusive_end.month, exclusive_end.day)]
  end

  def bounded_readback
    READBACK_DELAYS.each do |delay|
      sleep(delay) if delay.positive?
      result = yield
      return result if result
    end
    nil
  end

  def await_removed_reception(preflight_result)
    bounded_readback do
      candidate = read_reception_after_write(command.request_snapshot.fetch('provider_reception_code'), version: :v1)
      candidate = preflight_result.remote_reception.to_h.merge(candidate.to_h)
      candidate if removed_reception_matches?(candidate)
    end
  end

  def read_patient_after_write(patient_code)
    patient_by_code(patient_code)
  rescue Integrations::Medelement::Client::ApiError
    nil
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

  def created_reception_matches?(remote, patient_code)
    reception_verifier(patient_code).destination_match?(
      remote,
      expected_reception_code: command.provider_reception_code
    )
  end

  def moved_reception_matches?(remote, patient_code)
    reception_verifier(patient_code).moved_match?(remote)
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

  def patient_snapshot_matches?(patient)
    return false unless patient.is_a?(Hash)

    patient_data = command.request_snapshot.fetch('patient')
    desired = patient_data.fetch('payload')
    fields_match = {
      'name' => 'NAME',
      'lastname' => 'LASTNAME',
      'middlename' => 'MIDDLENAME',
      'patient_email' => 'PATIENT_EMAIL',
      'birthday' => 'BIRTHDAY',
      'gender' => 'GENDER',
      'iin' => 'IIN'
    }.all? do |local_key, remote_key|
      desired[local_key].blank? || desired[local_key].to_s == patient[remote_key].to_s
    end

    fields_match && Integrations::Medelement::PhoneNumber.new(patient_data.fetch('phone_number')).matches_patient?(patient)
  end

  def normalized_patient_write_response(response)
    response.to_h.transform_keys { |key| PATIENT_WRITE_RESPONSE_KEYS.fetch(key.to_s, key.to_s) }
  end

  def updated_patient_readback(response, patient_code)
    remote = normalized_patient_write_response(response)
    return remote if patient_reference_matches?(remote, patient_code) && patient_snapshot_matches?(remote)

    remote = read_patient_after_write(patient_code)
    return remote if patient_snapshot_matches?(remote)

    indexed_patient_after_write(patient_code)
  end

  def patient_reference_matches?(patient, expected_code)
    code = patient['PROFILE_CODE'].presence || patient['PATIENT_CODE'].presence
    code.to_s == expected_code.to_s
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

  def fail_command!(code:, status: nil, reconciliation: false)
    reconciliation &&= write_started?
    reconciliation_enqueued = false
    command.with_lock do
      next unless owns_claim?

      command.update!(
        status: reconciliation ? command.status_for_transition('reconciliation_required') : 'failed',
        last_error_code: code,
        last_error_status: status,
        executed_at: Time.current
      )
      reconciliation_enqueued = reconciliation
    end
    Integrations::Medelement::ProviderCommandReconciliationJob.perform_later(command.id) if reconciliation_enqueued
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
