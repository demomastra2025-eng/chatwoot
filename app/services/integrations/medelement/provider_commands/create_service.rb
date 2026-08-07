class Integrations::Medelement::ProviderCommands::CreateService
  CONFIRMATION_TTL = 30.minutes

  # This boundary mirrors the command API payload; keyword arguments keep call sites explicit.
  # rubocop:disable Metrics/ParameterLists
  def initialize(
    account:, hook:, operation:, idempotency_key:, appointment: nil, contact: nil, company_cabinet_code: nil,
    actor: nil, desired_starts_at: nil, desired_ends_at: nil
  )
    @account = account
    @hook = hook
    @appointment = appointment
    @contact = contact || appointment&.contact
    @operation = operation.to_s
    @idempotency_key = idempotency_key.to_s
    @company_cabinet_code = company_cabinet_code.to_s
    @actor = actor
    @desired_starts_at = desired_starts_at
    @desired_ends_at = desired_ends_at
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    validator.validate_identity!
    intent_fingerprint = idempotency_fingerprint
    existing = command_scope.find_by(idempotency_key: idempotency_key)
    return resolve_idempotent_duplicate!(existing, intent_fingerprint) if existing.present?

    create_new_command!(intent_fingerprint)
  rescue ActiveRecord::RecordNotUnique
    resolve_record_not_unique!(intent_fingerprint)
  end

  private

  attr_reader :account, :hook, :appointment, :contact, :operation, :idempotency_key,
              :company_cabinet_code, :actor, :desired_starts_at, :desired_ends_at

  def command_scope
    Integrations::Medelement::ProviderCommand.where(account: account)
  end

  def validator
    @validator ||= Integrations::Medelement::ProviderCommands::Validator.new(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: contact,
      operation: operation,
      idempotency_key: idempotency_key,
      company_cabinet_code: company_cabinet_code
    )
  end

  def create_new_command!(intent_fingerprint)
    validator.validate_request!
    snapshot = request_snapshot
    request_fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(snapshot)
    validator.validate_runtime!
    persist_command!(snapshot: snapshot, request_fingerprint: request_fingerprint, intent_fingerprint: intent_fingerprint)
  end

  def command_attributes(snapshot:, request_fingerprint:, intent_fingerprint:)
    {
      hook: hook,
      appointment: appointment,
      contact: contact,
      requested_by: actor,
      operation: operation,
      idempotency_key: idempotency_key,
      provider_patient_code: patient_code,
      provider_reception_code: reception_code,
      company_cabinet_code: company_cabinet_code.presence,
      desired_starts_at: desired_starts_at,
      desired_ends_at: desired_ends_at,
      execution_state: {
        'request_snapshot' => snapshot,
        'request_fingerprint' => request_fingerprint,
        'idempotency_fingerprint' => intent_fingerprint
      }
    }
  end

  def persist_command!(snapshot:, request_fingerprint:, intent_fingerprint:)
    ApplicationRecord.transaction do
      command = command_scope.create!(
        command_attributes(
          snapshot: snapshot,
          request_fingerprint: request_fingerprint,
          intent_fingerprint: intent_fingerprint
        ).merge(status: Integrations::Medelement::ProviderCommand.versioned_status('awaiting_confirmation'))
      )
      confirmation_request = create_confirmation_request(command)
      confirmation_state = command.execution_state.merge('confirmation_request_id' => confirmation_request.id)
      command.update!(confirmation_request: confirmation_request, execution_state: confirmation_state)
      command
    end
  end

  def request_snapshot
    Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: contact,
      actor: actor,
      operation: operation,
      company_cabinet_code: company_cabinet_code,
      desired_starts_at: desired_starts_at,
      desired_ends_at: desired_ends_at
    ).build
  end

  def resolve_idempotent_duplicate!(existing, intent_fingerprint)
    return existing if existing.execution_state.to_h['idempotency_fingerprint'] == intent_fingerprint

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_IDEMPOTENCY_KEY_REUSED',
      message: 'Medelement idempotency key was already used for a different command',
      status: :conflict
    )
  end

  def resolve_record_not_unique!(intent_fingerprint)
    duplicate = command_scope.find_by(idempotency_key: idempotency_key)
    return resolve_idempotent_duplicate!(duplicate, intent_fingerprint) if duplicate.present?

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_COMMAND_IN_PROGRESS',
      message: 'Another Medelement command is already in progress for this target',
      status: :conflict
    )
  end

  def idempotency_fingerprint
    intent = {
      'account_id' => account.id,
      'hook_id' => hook.id,
      'appointment_id' => appointment&.id,
      'contact_id' => contact&.id,
      'requested_by_id' => actor&.id,
      'operation' => operation,
      'company_cabinet_code' => company_cabinet_code.presence,
      'desired_starts_at' => serialized_time(desired_starts_at),
      'desired_ends_at' => serialized_time(desired_ends_at)
    }.compact
    Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(intent)
  end

  def serialized_time(value) = value&.utc&.iso8601(6)

  def create_confirmation_request(command)
    Confirmations::CreateService.new(
      account: account,
      title: confirmation_title,
      body: confirmation_body(command.request_snapshot),
      conversation: appointment&.conversation,
      contact: contact,
      subject: appointment,
      expires_at: CONFIRMATION_TTL.from_now,
      requester: actor,
      metadata: {
        'medelement_provider_command_id' => command.id,
        'operation' => operation,
        'request_fingerprint' => command.execution_state.fetch('request_fingerprint')
      },
      idempotency_key: "medelement-provider-command:#{idempotency_key}"
    ).perform
  end

  def patient_code
    contact_patient_code || appointment_patient_code
  end

  def appointment_patient_code = appointment&.custom_attributes&.to_h&.dig('medelement_patient_code').presence

  def contact_patient_code = contact&.custom_attributes&.to_h&.dig('medelement_patient_code').presence

  def reception_code
    return if appointment.blank?

    appointment.custom_attributes.to_h['medelement_reception_code'].presence ||
      appointment.external_ref.to_s.delete_prefix('medelement:reception:').presence
  end

  def confirmation_title
    {
      'create_patient' => 'Подтвердите создание пациента в Medelement',
      'update_patient' => 'Подтвердите обновление пациента в Medelement',
      'create_reception' => 'Подтвердите создание записи в Medelement',
      'move_reception' => 'Подтвердите перенос записи в Medelement',
      'remove_reception' => 'Подтвердите отмену записи в Medelement'
    }.fetch(operation)
  end

  def confirmation_body(snapshot)
    Integrations::Medelement::ProviderCommands::ConfirmationBodyBuilder.new(
      operation: operation,
      snapshot: snapshot
    ).build
  end
end
