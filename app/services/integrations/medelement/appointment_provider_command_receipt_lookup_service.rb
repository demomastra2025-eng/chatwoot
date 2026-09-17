class Integrations::Medelement::AppointmentProviderCommandReceiptLookupService
  def initialize(account:, appointment:, operation:)
    @account = account
    @appointment = appointment
    @operation = operation
  end

  def perform
    command = exact_command
    appointment.medelement_provider_command_receipt = command
    return command if command.present? || !provider_confirmation_pending?

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE',
      message: 'Medelement command receipt is temporarily unavailable',
      status: :service_unavailable
    )
  end

  private

  attr_reader :account, :appointment, :operation

  def exact_command
    binding = persisted_binding
    return unless binding.values.all?(&:present?)

    command = Integrations::Medelement::ProviderCommand.find_by(
      id: binding[:command_id],
      account_id: account.id,
      appointment_id: appointment.id,
      operation: operation,
      idempotency_key: binding[:idempotency_key]
    )
    return if command.blank?

    execution_state = command.execution_state.to_h
    return unless fingerprints_match?(execution_state['request_fingerprint'].to_s, binding[:fingerprint].to_s)
    return unless fingerprints_match?(execution_state['dispatch_identity'].to_s, binding[:dispatch_identity].to_s)

    command
  end

  def persisted_binding
    attributes = appointment.custom_attributes.to_h
    {
      command_id: attributes[Integrations::Medelement::AppointmentProviderStatus::COMMAND_ID_KEY],
      idempotency_key: attributes[Integrations::Medelement::AppointmentProviderStatus::COMMAND_IDEMPOTENCY_KEY],
      fingerprint: attributes[Integrations::Medelement::AppointmentProviderStatus::COMMAND_FINGERPRINT_KEY],
      dispatch_identity: attributes[Integrations::Medelement::AppointmentProviderStatus::COMMAND_DISPATCH_IDENTITY_KEY]
    }
  end

  def fingerprints_match?(first, second)
    first.present? && first.bytesize == second.bytesize && ActiveSupport::SecurityUtils.secure_compare(first, second)
  end

  def provider_confirmation_pending?
    appointment.custom_attributes.to_h[Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY] ==
      Integrations::Medelement::AppointmentProviderStatus::PENDING
  end
end
