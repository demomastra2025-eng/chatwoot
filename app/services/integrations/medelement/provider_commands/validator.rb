class Integrations::Medelement::ProviderCommands::Validator
  # Internal command validation boundary; keyword arguments make every invariant input explicit.
  # rubocop:disable Metrics/ParameterLists
  def initialize(account:, hook:, appointment:, contact:, operation:, idempotency_key:, company_cabinet_code:)
    @account = account
    @hook = hook
    @appointment = appointment
    @contact = contact
    @operation = operation
    @idempotency_key = idempotency_key
    @company_cabinet_code = company_cabinet_code
  end
  # rubocop:enable Metrics/ParameterLists

  def validate!
    validate_write_capability!
    validate_operation!
    validate_associations!
    validate_concurrency!
    validate_operation_prerequisites!
  end

  def validate_request!
    validate_identity!
    validate_operation_prerequisites!
  end

  def validate_identity!
    validate_operation!
    validate_associations!
  end

  def validate_runtime!
    validate_write_capability!
    validate_concurrency!
  end

  private

  attr_reader :account, :hook, :appointment, :contact, :operation, :idempotency_key, :company_cabinet_code

  def validate_write_capability!
    enabled = hook&.medelement? && hook.enabled? && hook.feature_allowed? &&
              Integrations::Medelement::Configuration.new(hook: hook).write_enabled?
    return if enabled

    raise Scheduling::Error.new(code: 'MEDELEMENT_WRITE_DISABLED', message: 'Medelement writes are disabled', status: :forbidden)
  end

  def validate_operation!
    operations = Integrations::Medelement::ProviderCommand::OPERATIONS
    raise ArgumentError, "operation must be one of: #{operations.join(', ')}" unless operation.in?(operations)
    raise ArgumentError, 'idempotency_key is required' if idempotency_key.blank?
  end

  def validate_associations!
    validate_account_associations!
    validate_appointment_contact!
  end

  def validate_account_associations!
    raise ArgumentError, 'hook must belong to the current account' unless hook.account_id == account.id
    raise ArgumentError, 'appointment must belong to the current account' if appointment.present? && appointment.account_id != account.id
    raise ArgumentError, 'contact must belong to the current account' if contact.present? && contact.account_id != account.id
  end

  def validate_appointment_contact!
    raise ArgumentError, 'contact must match the appointment contact' if appointment.present? && contact != appointment.contact
  end

  def validate_concurrency!
    scope = Integrations::Medelement::ProviderCommand.where(account: account).unfinished
    target_conflict = appointment.present? ? scope.exists?(appointment: appointment) : scope.exists?(contact: contact)
    return unless target_conflict || patient_identity_conflict?(scope)

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_COMMAND_IN_PROGRESS',
      message: 'Another Medelement command is in progress',
      status: :conflict
    )
  end

  def patient_identity_conflict?(scope)
    return false unless patient_identity_write?

    scope.patient_identity_writes.exists?(contact: contact)
  end

  def patient_identity_write?
    return false if contact.blank?

    operation.in?(%w[create_patient update_patient]) || (operation == 'create_reception' && appointment_patient_code.blank?)
  end

  def validate_operation_prerequisites!
    case operation
    when 'create_patient'
      require_contact!
    when 'update_patient'
      require_contact!
      require_patient_ref!
    when 'create_reception'
      require_appointment!
      require_contact!
      require_provider_resource!
    when 'move_reception'
      validate_move_prerequisites!
    when 'remove_reception'
      require_appointment!
      require_reception_ref!
    end
  end

  def require_appointment!
    raise ArgumentError, 'appointment is required' if appointment.blank?
  end

  def validate_move_prerequisites!
    require_appointment!
    require_reception_ref!
    require_contact!
    require_patient_ref!
    require_provider_resource!
  end

  def require_contact!
    raise ArgumentError, 'contact is required' if contact.blank?
  end

  def require_reception_ref!
    raise ArgumentError, 'appointment has no Medelement reception reference' if appointment.external_ref.blank?
  end

  def require_patient_ref!
    raise ArgumentError, 'contact has no Medelement patient reference' if patient_code.blank?
  end

  def require_provider_resource!
    attrs = appointment.resource.custom_attributes.to_h
    cabinet_codes = Array(attrs['medelement_cabinets']).pluck('companyCabinetCode').map(&:to_s)
    return if attrs['medelement_specialist_code'].present? && company_cabinet_code.to_s.in?(cabinet_codes)

    raise ArgumentError, 'company_cabinet_code must belong to the appointment Medelement specialist'
  end

  def patient_code
    appointment_patient_code || contact.custom_attributes.to_h['medelement_patient_code'].to_s
  end

  def appointment_patient_code
    appointment&.custom_attributes&.to_h&.dig('medelement_patient_code').presence
  end
end
