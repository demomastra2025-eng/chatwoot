class Captain::Tools::CancelAppointmentTool < Captain::Tools::BasePublicTool
  description 'Cancel the appointment linked to the current conversation'

  def perform(tool_context)
    appointment = operations(tool_context.state).cancel_current_appointment

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
