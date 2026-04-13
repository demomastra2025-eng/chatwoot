class Captain::Tools::CancelAppointmentTool < Captain::Tools::BasePublicTool
  description 'Cancel the appointment linked to the current conversation'

  def perform(tool_context)
    appointment = operations(tool_context.state).cancel_current_appointment

    "Cancelled appointment ##{appointment.id}"
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
