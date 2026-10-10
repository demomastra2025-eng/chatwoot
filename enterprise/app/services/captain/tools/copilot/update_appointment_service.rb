class Captain::Tools::Copilot::UpdateAppointmentService < Captain::Tools::Copilot::BaseAccountTool
  include Captain::Tools::Copilot::SchedulingQueryValidation
  def self.name
    'update_appointment'
  end

  description 'Update the selected appointment with a new specialist, service, or confirmed time details. ' \
              'For another patient, use the search token and first confirm their exact appointment with the caller. ' \
              'A pending provider result does not mean the change has been applied.'
  param :appointment_id, type: :number, desc: 'Exact appointment ID returned by get_appointment or a previous appointment mutation', required: false
  param :appointment_access_token, type: :string, desc: 'Opaque token from search_appointments for a specifically identified other patient appointment', required: false
  param :patient_confirmed, type: :boolean, desc: 'True only after the caller confirms the specific patient, doctor, time and requested change', required: false
  param :resource_id, type: :number, desc: 'Updated specialist resource ID', required: false
  param :service_id, type: :number, desc: 'Updated local service ID returned by search_scheduling_services', required: false
  param :starts_at, type: :string, desc: 'Updated appointment start datetime in ISO 8601 format', required: false
  param :ends_at, type: :string, desc: 'Optional updated appointment end datetime in ISO 8601 format', required: false
  param :duration_min, type: :number, desc: 'Optional updated appointment duration in minutes when ends_at is not provided', required: false
  param :appointment_type,
        type: :string,
        desc: 'Updated appointment type: primary, secondary, or other. Do not pass a specialty, service, or cabinet name.',
        required: false
  param :client_comment, type: :string, desc: 'Updated client comment', required: false
  param :custom_attributes,
        type: :object,
        desc: 'Optional scheduling custom attributes object. For Medelement, pass the selected ' \
              'resource.custom_attributes.medelement_cabinets[].companyCabinetCode as medelement_cabinet_code. For other keys, use the matching ' \
              'list_*_custom_fields tool first; only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  def execute(appointment_id: nil, resource_id: nil, service_id: nil, starts_at: nil, ends_at: nil, duration_min: nil, appointment_type: nil,
              client_comment: nil, custom_attributes: nil, appointment_access_token: nil, patient_confirmed: false)
    appointment = appointment_operations.update_current_appointment(
      appointment_id: appointment_id,
      appointment_access_token: appointment_access_token,
      patient_confirmed: patient_confirmed,
      resource_id: resource_id,
      service_id: service_id,
      starts_at: starts_at,
      ends_at: ends_at,
      duration_min: duration_min,
      appointment_type: appointment_type,
      client_comment: client_comment,
      custom_attributes: custom_attributes
    )
    return formatted_payload(Captain::Tools::Agent::AppointmentResult.success(appointment, action: self.class.name)) if patient_scope

    formatted_payload(
      ::Scheduling::ToolPayloadBuilder.appointment_payload(action: 'update_appointment', appointment: appointment)
    )
  rescue Scheduling::Error => e
    return formatted_payload(Captain::Tools::Agent::AppointmentResult.failure(e)) if patient_scope

    Captain::ToolResult.failure_output(error: e.message, data: { code: e.code, reason: e.details.to_h[:reason] }.compact, retryable: false)
  rescue StandardError => e
    return formatted_payload(Captain::Tools::Agent::AppointmentResult.failure(e)) if patient_scope

    e.is_a?(ArgumentError) || e.is_a?(ActiveRecord::RecordInvalid) || e.is_a?(ActiveRecord::RecordNotFound) ? tool_failure(e) : scheduling_tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  def appointment_operations
    Captain::Tools::Operations::AppointmentOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end
end
