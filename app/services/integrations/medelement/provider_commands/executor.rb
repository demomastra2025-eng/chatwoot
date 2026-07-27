class Integrations::Medelement::ProviderCommands::Executor
  def initialize(command:)
    @command = command
  end

  def perform
    return unless claim!

    validate_execution_gate!
    execute_operation!
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
  rescue StandardError => e
    Rails.logger.error("[MEDELEMENT::PROVIDER_COMMAND] command_id=#{command.id} error=#{e.class}")
    fail_command!(code: 'executor_error', reconciliation: write_started?)
  end

  private

  attr_reader :command

  def claim!
    command.with_lock do
      next false unless command.queued?

      command.update!(
        status: 'processing',
        attempt_count: command.attempt_count + 1,
        last_error_code: nil,
        last_error_status: nil
      )
      true
    end
  end

  def validate_execution_gate!
    confirmation = command.confirmation_request
    enabled = command.hook.enabled? && command.hook.feature_allowed? && configuration.write_enabled?
    return if enabled && confirmation&.confirmed?

    raise Integrations::Medelement::ProviderCommands::ExecutionError.new(
      code: 'execution_gate_closed',
      message: 'Medelement write confirmation or capability is missing'
    )
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
    mark_write_phase!('patient_update')
    payload = Integrations::Medelement::ProviderCommands::PatientPayloadBuilder.new(
      contact: command.contact,
      patient_code: command.provider_patient_code
    ).build
    client.update_patient(params: payload)
    success_applier.patient!(patient_code: command.provider_patient_code)
  end

  def create_reception!
    patient_code = patient_resolver.resolve!(allow_create: true)
    preflight_result = preflight.perform
    mark_write_phase!('reception_create', preflight_result.reception_codes)
    response = client.create_reception(params: reception_payload_builder.create_payload(patient_code: patient_code))
    reception_code = response.is_a?(Hash) ? response['reception_code'].presence || response['RECEPTION_CODE'].presence : nil
    raise reconciliation_error('reception_create_missing_ref') if reception_code.blank?

    success_applier.reception_created!(reception_code: reception_code.to_s)
  end

  def move_reception!
    patient_code = patient_resolver.resolve!(allow_create: false)
    preflight_result = preflight.perform
    mark_write_phase!('reception_move', preflight_result.reception_codes)
    client.move_reception(params: reception_payload_builder.move_payload(patient_code: patient_code))
    success_applier.reception_moved!
  end

  def remove_reception!
    result = preflight.perform
    return success_applier.reception_removed! if result.remote_reception['REMOVED'].to_i == 1

    mark_write_phase!('reception_remove')
    client.remove_reception(reception_code: command.provider_reception_code)
    success_applier.reception_removed!
  end

  def patient_resolver
    @patient_resolver ||= Integrations::Medelement::ProviderCommands::PatientResolver.new(command: command, client: client)
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

  def mark_write_phase!(phase, preflight_reception_codes = nil)
    state = command.execution_state.merge('write_phase' => phase)
    state['preflight_reception_codes'] = preflight_reception_codes if preflight_reception_codes
    command.update!(execution_state: state)
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
    command.with_lock do
      next unless command.processing?

      command.update!(
        status: reconciliation ? 'reconciliation_required' : 'failed',
        last_error_code: code,
        last_error_status: status,
        executed_at: Time.current
      )
    end
  end
end
