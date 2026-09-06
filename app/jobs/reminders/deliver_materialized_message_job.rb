class Reminders::DeliverMaterializedMessageJob < ApplicationJob
  queue_as :outbound_messages

  discard_on ActiveRecord::RecordNotFound

  def perform(reminder_id, message_id, processing_claim)
    reminder = Reminder.find(reminder_id)
    appointment = provider_appointment(reminder)
    return dispatch_with_appointment_lock!(appointment, reminder, message_id, processing_claim) if appointment.present?

    dispatch_if_current!(reminder, message_id, processing_claim)
  end

  private

  def dispatch_with_appointment_lock!(appointment, reminder, message_id, processing_claim)
    appointment.with_lock do
      appointment.reload
      dispatch_if_current!(reminder, message_id, processing_claim)
    end
  end

  def dispatch_if_current!(reminder, message_id, processing_claim)
    reminder.with_lock do
      reminder.reload
      next unless dispatchable?(reminder, message_id, processing_claim)

      message = Message.outgoing.find_by!(id: message_id, account_id: reminder.account_id)
      next unless message.additional_attributes.to_h['touch_id'].to_s == reminder.id.to_s
      next if provider_guard_stops?(reminder)

      SendReplyJob.perform_now(message.id)
      reminder.mark_delivery_dispatched!(message.id)
    end
  end

  def dispatchable?(reminder, message_id, processing_claim)
    (reminder.processing? || reminder.completed?) &&
      reminder.processing_claim_token == processing_claim &&
      materialized_message_id(reminder) == message_id.to_s &&
      !reminder.delivery_dispatched_for?(message_id)
  end

  def provider_guard_stops?(reminder)
    Reminders::AppointmentProviderGuard.new(reminder: reminder, phase: :delivery).perform ==
      Reminders::AppointmentProviderGuard::STOP
  end

  def materialized_message_id(reminder)
    reminder.metadata.to_h[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY].to_s
  end

  def provider_appointment(reminder)
    return unless reminder.remindable_type == 'Scheduling::Appointment'

    reminder.remindable
  end
end
