module Scheduling::ToolPayloadBuilder
  module_function

  def appointment_payload(action:, appointment:, provider_write_acknowledged: false)
    appointment_data = appointment_data_for(appointment, provider_write_acknowledged)
    provider_command_receipt = provider_receipt_for(appointment)

    {
      action: action,
      appointment_id: appointment_data[:id],
      status: provider_write_acknowledged ? appointment.status : Integrations::Medelement::AppointmentProviderStatus.public_status(appointment),
      provider_confirmation_status: appointment_data[:provider_confirmation_status],
      provider_confirmed: appointment_data[:provider_confirmed],
      provider_confirmation_operation: appointment_data[:provider_confirmation_operation],
      provider_confirmation_scope: appointment_data[:provider_confirmation_scope],
      provider_write_acknowledged: provider_write_acknowledged ? true : nil,
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

  def provider_receipt_for(appointment)
    Integrations::Medelement::ProviderCommandReceiptBuilder.build(command: appointment.medelement_provider_command_receipt)
  end

  def appointment_data_for(appointment, provider_write_acknowledged)
    data = Scheduling::PayloadBuilder.appointment(appointment)
    return data unless provider_write_acknowledged

    data.merge(provider_confirmation_status: 'acknowledged', provider_confirmed: true)
  end

  def provider_confirmation_required?(appointment)
    return false if appointment.status == 'cancelled' && Integrations::Medelement::LocalCancellation.marked?(appointment)

    appointment.resource&.custom_attributes.to_h['medelement_specialist_code'].present? &&
      appointment.custom_attributes.to_h[Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY].present?
  end
end
