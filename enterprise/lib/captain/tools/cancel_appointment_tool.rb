class Captain::Tools::CancelAppointmentTool < Captain::Tools::BasePublicTool
  description 'Cancel the appointment linked to the current conversation'
  param :appointment_id, type: 'number', desc: 'Exact appointment ID returned by get_appointment or a previous appointment mutation', required: false

  def perform(tool_context, appointment_id: nil)
    appointment = operations(tool_context.state).cancel_current_appointment(appointment_id: appointment_id)

    JSON.pretty_generate(::Scheduling::ToolPayloadBuilder.appointment_payload(action: 'cancel_appointment', appointment: appointment))
  rescue StandardError => e
    tool_failure(e)
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
