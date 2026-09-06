class Integrations::Medelement::AppointmentProviderCommandReceiptLookupService
  def initialize(account:, appointment:, operation:)
    @account = account
    @appointment = appointment
    @operation = operation
  end

  def perform
    command = Integrations::Medelement::ProviderCommand.where(
      account_id: account.id,
      appointment_id: appointment.id,
      operation: operation
    ).order(created_at: :desc, id: :desc).first
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

  def provider_confirmation_pending?
    appointment.custom_attributes.to_h[Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY] ==
      Integrations::Medelement::AppointmentProviderStatus::PENDING
  end
end
