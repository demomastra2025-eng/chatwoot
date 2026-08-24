class Captain::Tools::UpdateAppointmentTool < Captain::Tools::BasePublicTool
  description 'Update the appointment linked to the current conversation with a new specialist, service, or confirmed time details'
  param :resource_id, type: 'number', desc: 'Updated specialist resource ID', required: false
  param :service_id, type: 'number', desc: 'Updated local service ID returned by search_scheduling_services', required: false
  param :starts_at, type: 'string', desc: 'Updated appointment start datetime in ISO 8601 format', required: false
  param :ends_at, type: 'string', desc: 'Optional updated appointment end datetime in ISO 8601 format', required: false
  param :duration_min, type: 'number', desc: 'Optional updated appointment duration in minutes when ends_at is not provided', required: false
  param :appointment_type,
        type: 'string',
        desc: 'Updated appointment type: primary, secondary, or other. Do not pass a specialty, service, or cabinet name.',
        required: false
  param :client_comment, type: 'string', desc: 'Updated client comment', required: false
  param :custom_attributes,
        type: 'object',
        desc: 'Optional scheduling custom attributes object. For Medelement, pass the selected ' \
              'resource.custom_attributes.medelement_cabinets[].companyCabinetCode as medelement_cabinet_code. For other keys, use the matching ' \
              'list_*_custom_fields tool first; only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  def perform(tool_context, resource_id: nil, service_id: nil, starts_at: nil, ends_at: nil, duration_min: nil, appointment_type: nil,
              client_comment: nil, custom_attributes: nil)
    appointment = operations(tool_context.state).update_current_appointment(
      resource_id: resource_id,
      service_id: service_id,
      starts_at: starts_at,
      ends_at: ends_at,
      duration_min: duration_min,
      appointment_type: appointment_type,
      client_comment: client_comment,
      custom_attributes: custom_attributes
    )

    JSON.pretty_generate(::Scheduling::ToolPayloadBuilder.appointment_payload(action: 'update_appointment', appointment: appointment))
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
