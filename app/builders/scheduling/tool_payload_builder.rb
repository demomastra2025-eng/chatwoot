module Scheduling::ToolPayloadBuilder
  module_function

  def appointment_payload(action:, appointment:)
    appointment_data = Scheduling::PayloadBuilder.appointment(appointment)
    provider_command_receipt = Integrations::Medelement::ProviderCommandReceiptBuilder.build(
      command: appointment.medelement_provider_command_receipt
    )

    {
      action: action,
      appointment_id: appointment_data[:id],
      status: Integrations::Medelement::AppointmentProviderStatus.public_status(appointment),
      provider_confirmation_status: appointment_data[:provider_confirmation_status],
      provider_confirmed: appointment_data[:provider_confirmed],
      provider_confirmation_required: provider_confirmation_required?(appointment),
      resource_id: appointment_data[:resource_id],
      resource_name: appointment_data[:resource_name],
      contact_id: appointment_data[:contact_id],
      service_id: appointment_data[:service_id],
      starts_at: appointment_data[:starts_at],
      ends_at: appointment_data[:ends_at],
      provider_command_receipt: provider_command_receipt,
      appointment: appointment_data
    }.compact
  end

  def provider_confirmation_required?(appointment)
    appointment.resource&.custom_attributes.to_h['medelement_specialist_code'].present?
  end
end
