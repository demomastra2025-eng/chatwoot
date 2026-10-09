class Captain::Tools::Copilot::GetAppointmentService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_appointment'
  end

  description 'Get details of an appointment'
  param :appointment_id, type: :number, desc: 'The appointment ID', required: true

  def execute(appointment_id:)
    appointment_id = required_positive_id(appointment_id, field_name: 'appointment_id')
    appointments = patient_scope ? patient_scope.appointments : account.scheduling_appointments
    appointment = appointments.includes(
      :resource,
      :service,
      :company,
      :contact,
      conversation: [:inbox, :communication_thread]
    ).find_by(id: appointment_id)
    if appointment.blank?
      return formatted_payload(success: false, reason: 'not_found') if patient_scope

      return tool_failure('Appointment not found')
    end

    return formatted_payload(Captain::Tools::Agent::AppointmentResult.success(appointment)) if patient_scope

    formatted_payload(appointment: ::Scheduling::PayloadBuilder.appointment(appointment))
  rescue StandardError => e
    raise unless patient_scope

    formatted_payload(Captain::Tools::Agent::AppointmentResult.failure(e))
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end
end
