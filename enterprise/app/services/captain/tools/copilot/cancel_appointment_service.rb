class Captain::Tools::Copilot::CancelAppointmentService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'cancel_appointment'
  end

  description 'Cancel the selected appointment after confirming the exact patient, doctor and time. ' \
              'For another patient use the search token. A pending provider result is not a completed cancellation; ' \
              'a local-only cancellation leaves the MedElement reception active.'
  param :appointment_id, type: :number, desc: 'Exact appointment ID returned by get_appointment or a previous appointment mutation', required: false
  param :appointment_access_token, type: :string, desc: 'Opaque token from search_appointments for a specifically identified other patient appointment', required: false
  param :patient_confirmed, type: :boolean, desc: 'True only after the caller confirms the specific patient, doctor, time and cancellation', required: false

  def execute(appointment_id: nil, appointment_access_token: nil, patient_confirmed: false)
    appointment = appointment_operations.cancel_current_appointment(
      appointment_id: appointment_id, appointment_access_token: appointment_access_token, patient_confirmed: patient_confirmed
    )
    return formatted_payload(Captain::Tools::Agent::AppointmentResult.success(appointment, action: self.class.name)) if patient_scope

    formatted_payload(
      ::Scheduling::ToolPayloadBuilder.appointment_payload(action: 'cancel_appointment', appointment: appointment)
    )
  rescue StandardError => e
    patient_scope ? formatted_payload(Captain::Tools::Agent::AppointmentResult.failure(e)) : tool_failure(e)
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
