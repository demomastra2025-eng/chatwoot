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
    existing = command_scope.find_by(idempotency_key: idempotency_key)
    return existing if existing.present?

    validate!
    command = nil
    ApplicationRecord.transaction do
      command = command_scope.create!(command_attributes)
      command.update!(confirmation_request: create_confirmation_request(command))
    end
    command
  rescue ActiveRecord::RecordNotUnique
    duplicate = command_scope.find_by(idempotency_key: idempotency_key)
    return duplicate if duplicate.present?

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_COMMAND_IN_PROGRESS',
      message: 'Another Medelement command is already in progress for this target',
      status: :conflict
    )
  end

  private

  attr_reader :account, :hook, :appointment, :contact, :operation, :idempotency_key,
              :company_cabinet_code, :actor, :desired_starts_at, :desired_ends_at

  def command_scope
    Integrations::Medelement::ProviderCommand.where(account: account)
  end

  def validate!
    Integrations::Medelement::ProviderCommands::Validator.new(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: contact,
      operation: operation,
      idempotency_key: idempotency_key,
      company_cabinet_code: company_cabinet_code
    ).validate!
  end

  def command_attributes
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
      desired_ends_at: desired_ends_at
    }
  end

  def create_confirmation_request(command)
    Confirmations::CreateService.new(
      account: account,
      title: confirmation_title,
      body: confirmation_body,
      conversation: appointment&.conversation,
      contact: contact,
      subject: appointment,
      expires_at: CONFIRMATION_TTL.from_now,
      requester: actor,
      metadata: { 'medelement_provider_command_id' => command.id, 'operation' => operation },
      idempotency_key: "medelement-provider-command:#{idempotency_key}"
    ).perform
  end

  def patient_code
    contact&.custom_attributes&.dig('medelement_patient_code').presence
  end

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

  def confirmation_body
    return "Новая дата: #{desired_starts_at.in_time_zone.iso8601} — #{desired_ends_at.in_time_zone.iso8601}" if operation == 'move_reception'
    return "Операция #{operation} для записи ##{appointment.id}" if appointment.present?

    "Операция #{operation} для контакта ##{contact.id}"
  end
end
