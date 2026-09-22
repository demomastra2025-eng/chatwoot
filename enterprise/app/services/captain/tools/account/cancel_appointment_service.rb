class Captain::Tools::Account::CancelAppointmentService < Captain::Tools::Account::BaseAccountTool
  def self.name
    'cancel_appointment'
  end

  description 'Cancel the appointment linked to the current conversation'
  param :appointment_id, type: :number, desc: 'Exact appointment ID returned by get_appointment or a previous appointment mutation', required: false

  def execute(appointment_id: nil)
    appointment = appointment_operations.cancel_current_appointment(appointment_id: appointment_id)
    formatted_payload(
      ::Scheduling::ToolPayloadBuilder.appointment_payload(
        action: 'cancel_appointment',
        appointment: appointment,
        include_finance: appointment_finance_visible?(appointment)
      )
    )
  rescue StandardError => e
    tool_failure(e)
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
