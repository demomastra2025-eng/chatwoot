class CrmAppointmentAutomationListener < BaseListener
  def message_created(event)
    message = event.data[:message]
    return unless message&.incoming? && !message.private?

    Crm::Appointments::InboundDealJob.perform_later(message.account_id, message.id)
  rescue StandardError => e
    Rails.logger.warn("CRM inbound enqueue failed: message_id=#{message&.id} error=#{e.class.name}")
  end

  def appointment_created(event)
    appointment = event.data[:appointment]
    return unless appointment

    Crm::Appointments::AppointmentChangedJob.perform_later(appointment.account_id, appointment.id, true)
  end

  def appointment_updated(event)
    appointment = event.data[:appointment]
    return unless appointment

    Crm::Appointments::AppointmentChangedJob.perform_later(appointment.account_id, appointment.id, false)
  end
end
