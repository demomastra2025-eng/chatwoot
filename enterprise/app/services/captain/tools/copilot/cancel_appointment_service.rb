class Captain::Tools::Copilot::CancelAppointmentService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'cancel_appointment'
  end

  description 'Cancel the appointment linked to the current conversation'

  def execute
    appointment = appointment_operations.cancel_current_appointment
    formatted_record(appointment)
  rescue StandardError => e
    e.message
  end

  def active?
    current_appointment.present? && @user.present? && assistant.account.feature_enabled?('scheduling')
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
