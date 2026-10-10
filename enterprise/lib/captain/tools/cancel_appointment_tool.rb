class Captain::Tools::CancelAppointmentTool < Captain::Tools::BasePublicTool
  description 'Cancel a specifically identified appointment. For another patient use the search task token and confirm the exact cancellation. ' \
              'A cancelled_local_only result means the MedElement reception remains active; tell the caller clearly. ' \
              'Do not claim provider cancellation while confirmation is pending.'
  param :appointment_id, type: 'number', desc: 'Exact appointment ID returned by get_appointment or a previous appointment mutation', required: false
  param :appointment_access_token, type: 'string', desc: 'Opaque token from search_appointments for a specifically identified other patient appointment', required: false
  param :patient_confirmed, type: 'boolean', desc: 'True only after the caller confirms the specific patient, doctor, time and cancellation', required: false

  def perform(tool_context, appointment_id: nil, appointment_access_token: nil, patient_confirmed: false)
    appointment = operations(tool_context.state).cancel_current_appointment(
      appointment_id: appointment_id, appointment_access_token: appointment_access_token, patient_confirmed: patient_confirmed
    )

    JSON.generate(Captain::Tools::Agent::AppointmentResult.success(appointment, action: 'cancel_appointment'))
  rescue StandardError => e
    JSON.generate(Captain::Tools::Agent::AppointmentResult.failure(e))
  end

  private

  def operations(state)
    Captain::Tools::Operations::AppointmentOperations.new(
      assistant: assistant,
      conversation: current_conversation(state),
      actor: assistant
    )
  end
end
