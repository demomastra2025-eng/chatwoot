class Captain::Tools::CreateAppointmentTool < Captain::Tools::BasePublicTool
  description 'Create an appointment for the current conversation contact'
  param :resource_id, type: 'number', desc: 'Specialist resource ID', required: true
  param :starts_at, type: 'string', desc: 'Appointment start datetime', required: true
  param :ends_at, type: 'string', desc: 'Appointment end datetime', required: true
  param :service_id, type: 'number', desc: 'Service ID', required: false
  param :appointment_type, type: 'string', desc: 'Appointment type', required: false
  param :client_comment, type: 'string', desc: 'Client comment', required: false
  param :custom_attributes_json, type: 'string', desc: 'Optional custom attributes as JSON object', required: false

  def perform(tool_context, resource_id:, starts_at:, ends_at:, service_id: nil, appointment_type: nil, client_comment: nil, custom_attributes_json: nil)
    appointment = operations(tool_context.state).create_appointment(
      resource_id: resource_id,
      service_id: service_id,
      starts_at: starts_at,
      ends_at: ends_at,
      appointment_type: appointment_type,
      client_comment: client_comment,
      custom_attributes: custom_attributes_json
    )

    "Created appointment ##{appointment.id} starting at #{appointment.starts_at}"
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def operations(state)
    Captain::Tools::Operations::AppointmentOperations.new(
      assistant: assistant,
      conversation: current_conversation(state)
    )
  end
end
