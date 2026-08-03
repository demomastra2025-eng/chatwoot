class Captain::Tools::Copilot::GetAppointmentService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_appointment'
  end

  description 'Get details of an appointment'
  param :appointment_id, type: :number, desc: 'The appointment ID', required: true

  def execute(appointment_id:)
    appointment_id = required_positive_id(appointment_id, field_name: 'appointment_id')
    appointment = account.scheduling_appointments.includes(
      :resource,
      :service,
      :company,
      :contact,
      conversation: [:inbox, :communication_thread]
    ).find_by(id: appointment_id)
    return tool_failure('Appointment not found') if appointment.blank?

    formatted_payload(appointment: ::Scheduling::PayloadBuilder.appointment(appointment))
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end
end
