class Captain::Tools::UpdateAppointmentTool < Captain::Tools::BasePublicTool
  description 'Update the appointment linked to the current conversation'
  param :resource_id, type: 'number', desc: 'Updated specialist resource ID', required: false
  param :service_id, type: 'number', desc: 'Updated service ID', required: false
  param :starts_at, type: 'string', desc: 'Updated appointment start datetime', required: false
  param :ends_at, type: 'string', desc: 'Updated appointment end datetime', required: false
  param :appointment_type, type: 'string', desc: 'Updated appointment type', required: false
  param :client_comment, type: 'string', desc: 'Updated client comment', required: false
  param :custom_attributes_json, type: 'string', desc: 'Optional custom attributes as JSON object', required: false

  def perform(tool_context, resource_id: nil, service_id: nil, starts_at: nil, ends_at: nil, appointment_type: nil, client_comment: nil, custom_attributes_json: nil)
    appointment = operations(tool_context.state).update_current_appointment(
      resource_id: resource_id,
      service_id: service_id,
      starts_at: starts_at,
      ends_at: ends_at,
      appointment_type: appointment_type,
      client_comment: client_comment,
      custom_attributes: custom_attributes_json
    )

    "Updated appointment ##{appointment.id}"
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
