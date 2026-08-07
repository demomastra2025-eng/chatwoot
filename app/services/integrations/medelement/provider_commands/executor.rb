# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ProviderCommands::Executor
  class ClaimLost < StandardError; end

  def initialize(command:)
    @command = command
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
  rescue ClaimLost
    nil
  rescue StandardError => e
    Rails.logger.error("[MEDELEMENT::PROVIDER_COMMAND] command_id=#{command.id} error=#{e.class}")
    fail_command!(code: 'executor_error', reconciliation: write_started?)
  end
  # rubocop:enable Metrics/MethodLength

  private

  attr_reader :command

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
    return if command.request_snapshot_valid?

    raise execution_error('request_snapshot_invalid', 'Medelement confirmed request snapshot is missing or invalid')
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
    mark_write_phase!('patient_update', provider_patient_code: patient_code)
    client.update_patient(params: payload)
    remote = read_patient_after_write(patient_code)
    raise reconciliation_error('patient_update_pending_materialization') unless patient_snapshot_matches?(remote)

    success_applier.patient!(patient_code: patient_code)
  end

  def create_reception!
    patient_code = patient_resolver.resolve!(allow_create: true)
    preflight_result = preflight.perform
    reception_code = create_remote_reception!(patient_code: patient_code, preflight_result: preflight_result)
    remote = read_reception_after_write(reception_code)
    raise reconciliation_error('reception_create_pending_materialization') unless created_reception_matches?(remote, patient_code)

    success_applier.reception_created!(reception_code: reception_code, patient_code: patient_code)
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
    remote = read_reception_after_write(command.request_snapshot.fetch('provider_reception_code'))
    raise reconciliation_error('reception_move_pending_materialization') unless moved_reception_matches?(remote, patient_code)

    success_applier.reception_moved!
  end

  def remove_reception!
    result = preflight.perform
    return success_applier.reception_removed! if result.remote_reception['REMOVED'].to_i == 1

    mark_write_phase!('reception_remove')
    client.remove_reception(reception_code: command.request_snapshot.fetch('provider_reception_code'))
    remote = read_reception_after_write(command.request_snapshot.fetch('provider_reception_code'))
    raise reconciliation_error('reception_remove_pending_materialization') unless remote.is_a?(Hash) && remote['REMOVED'].to_i == 1

    success_applier.reception_removed!
  end

  def patient_resolver
    @patient_resolver ||= Integrations::Medelement::ProviderCommands::PatientResolver.new(
      command: command,
      client: client,
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
    command.update!(
      provider_reception_code: provider_reception_code,
      execution_state: command.execution_state.merge('write_provider_reception_code' => provider_reception_code)
    )
  end

  def read_reception_after_write(reception_code)
    client.get_reception(reception_code: reception_code, version: :v2)
  rescue Integrations::Medelement::Client::ApiError
    nil
  end

  def read_patient_after_write(patient_code)
    client.get_patient(patient_code: patient_code)
  rescue Integrations::Medelement::Client::ApiError
    nil
  end

  def created_reception_matches?(remote, patient_code)
    return false unless moved_reception_matches?(remote, patient_code)

    expected_codes = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.service_codes(command.request_snapshot)
    actual_codes = Array(remote['SERVICES']).filter_map do |service|
      service['NOMENCLATURE_CODE'].to_s.presence if service.is_a?(Hash)
    end
    (expected_codes - actual_codes).empty?
  end

  def moved_reception_matches?(remote, patient_code)
    return false unless remote.is_a?(Hash) && remote['REMOVED'].to_i.zero?

    remote_patient_code = remote['PROFILE_CODE'].presence || remote['PATIENT_CODE'].presence
    return false unless remote_patient_code.to_s == patient_code.to_s

    remote_destination_times_match?(remote)
  end

  def remote_destination_times_match?(remote)
    provider_time(remote['STARTTIME'])&.to_i == snapshot_time('destination_starts_at').to_i &&
      provider_time(remote['ENDTIME'])&.to_i == snapshot_time('destination_ends_at').to_i
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

  def snapshot_time(key)
    Time.iso8601(command.request_snapshot.fetch('reception').fetch(key))
  end

  def provider_time(value)
    zone = command.request_snapshot.dig('reception', 'time_zone')
    ActiveSupport::TimeZone[zone].parse(value.to_s)
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
