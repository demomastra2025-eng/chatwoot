module Scheduling::ToolPayloadBuilder
  module_function

  def appointment_payload(action:, appointment:)
    appointment_data = Scheduling::PayloadBuilder.appointment(appointment)

    {
      action: action,
      appointment_id: appointment_data[:id],
      status: appointment_data[:status],
      resource_id: appointment_data[:resource_id],
      resource_name: appointment_data[:resource_name],
      contact_id: appointment_data[:contact_id],
      service_id: appointment_data[:service_id],
      starts_at: appointment_data[:starts_at],
      ends_at: appointment_data[:ends_at],
      appointment: appointment_data
    }.compact
  end
end
