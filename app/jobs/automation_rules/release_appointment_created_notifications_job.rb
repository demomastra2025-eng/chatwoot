class AutomationRules::ReleaseAppointmentCreatedNotificationsJob < ApplicationJob
  queue_as :medelement_provider_commands

  BATCH_SIZE = 200

  def perform(command_id = nil)
    return release(command_id) if command_id.present?

    Integrations::Medelement::ProviderCommand.joins(:appointment)
      .where(operation: 'create_reception', status: 'succeeded')
      .where("scheduling_appointments.custom_attributes ? 'appointment_created_notification_hold'")
      .where("scheduling_appointments.custom_attributes ->> 'medelement_provider_command_id' = medelement_provider_commands.id::text")
      .where("COALESCE(medelement_provider_commands.execution_state ->> 'appointment_created_notification_complete', 'false') = 'false'")
      .in_batches(of: BATCH_SIZE) do |batch|
        batch.pluck(:id).each { |id| self.class.perform_later(id) }
      end
  end

  private

  def release(command_id)
    command = Integrations::Medelement::ProviderCommand.find_by(id: command_id)
    AutomationRules::AppointmentCreatedNotificationHold.new(command: command).perform if command
  end
end
