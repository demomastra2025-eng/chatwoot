class Crm::Appointments::AppointmentChangedJob < ApplicationJob
  queue_as :low

  def perform(account_id, appointment_id, created = false)
    appointment = Scheduling::Appointment.find_by(account_id: account_id, id: appointment_id)
    return unless appointment && appointment.account.feature_enabled?('crm_deals')

    if created && appointment.source == 'medelement' && appointment.crm_deal_id.blank?
      appointment.with_lock do
        Crm::Appointments::LinkService.new(appointment: appointment, newly_imported: true).perform
        appointment.save! if appointment.changed?
      end
    end
    Crm::Appointments::EvaluateDealJob.perform_later(account_id, appointment.crm_deal_id) if appointment.crm_deal_id.present?
  end
end
