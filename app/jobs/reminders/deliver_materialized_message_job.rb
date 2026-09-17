class Reminders::DeliverMaterializedMessageJob < MutexApplicationJob
  queue_as :outbound_messages

  LOCK_TIMEOUT = 10.minutes
  UNCONFIRMED_PROVIDER_DELIVERY = 'Outbound provider did not confirm message submission'.freeze
  WHATSAPP_CHANNEL_TYPES = %w[Channel::Whatsapp Channel::WhatsappWeb].freeze

  discard_on ActiveRecord::RecordNotFound
  retry_on LockAcquisitionError, wait: 5.seconds, attempts: :unlimited

  def perform(reminder_id, message_id, processing_claim)
    with_lock(delivery_lock_key(reminder_id), LOCK_TIMEOUT) do |renew_lock|
      dispatch!(reminder_id, message_id, processing_claim, renew_lock)
    end
  end

  private

  def dispatch!(reminder_id, message_id, processing_claim, renew_lock)
    reminder = Reminder.find(reminder_id)
    provider_guard = Reminders::AppointmentProviderGuard.new(reminder: reminder, phase: :delivery)
    provider_check = [provider_guard, provider_guard.verify]
    raise LockAcquisitionError, 'Lost reminder delivery mutex before provider dispatch' unless renew_lock.call

    message = prepare_dispatch(reminder, message_id, processing_claim, provider_check)
    return if message.blank?

    SendReplyJob.perform_now(message.id)
    finalize_dispatch(reminder, message, processing_claim)
  end

  def prepare_dispatch(reminder, message_id, processing_claim, provider_check)
    appointment = provider_appointment(reminder)
    return prepare_with_appointment_lock(appointment, reminder, message_id, processing_claim, provider_check) if appointment.present?

    prepare_with_reminder_lock(reminder, message_id, processing_claim, provider_check)
  end

  def prepare_with_appointment_lock(appointment, reminder, message_id, processing_claim, provider_check)
    appointment.with_lock do
      appointment.reload
      prepare_with_reminder_lock(reminder, message_id, processing_claim, provider_check)
    end
  end

  def prepare_with_reminder_lock(reminder, message_id, processing_claim, provider_check)
    reminder.with_lock do
      reminder.reload
      next unless dispatchable?(reminder, message_id, processing_claim)

      message = Message.outgoing.find_by!(id: message_id, account_id: reminder.account_id)
      next unless message.additional_attributes.to_h['touch_id'].to_s == reminder.id.to_s
      next if provider_guard_stops?(*provider_check)

      message
    end
  end

  def finalize_dispatch(reminder, message, processing_claim)
    message.reload
    return mark_failed_delivery(reminder, message, processing_claim) if message.failed?
    return mark_dispatched(reminder, message.id, processing_claim) if delivery_handed_off?(message)

    message.update!(status: :failed, external_error: UNCONFIRMED_PROVIDER_DELIVERY)
    mark_failed_delivery(reminder, message, processing_claim)
  end

  def mark_dispatched(reminder, message_id, processing_claim)
    reminder.with_lock do
      reminder.reload
      reminder.mark_delivery_dispatched!(message_id) if dispatchable?(reminder, message_id, processing_claim)
    end
  end

  def mark_failed_delivery(reminder, message, processing_claim)
    reminder.with_lock do
      reminder.reload
      next unless dispatchable?(reminder, message.id, processing_claim)

      reminder.fail!(message.external_error.presence || UNCONFIRMED_PROVIDER_DELIVERY)
    end
  end

  def dispatchable?(reminder, message_id, processing_claim)
    (reminder.processing? || reminder.completed?) &&
      reminder.processing_claim_token == processing_claim &&
      materialized_message_id(reminder) == message_id.to_s &&
      !reminder.delivery_dispatched_for?(message_id)
  end

  def provider_guard_stops?(provider_guard, provider_verification)
    provider_guard.perform(verification: provider_verification) == Reminders::AppointmentProviderGuard::STOP
  end

  def delivery_handed_off?(message)
    return true unless WHATSAPP_CHANNEL_TYPES.include?(message.inbox.channel_type)
    return true if message.source_id.present?

    Whatsapp::Providers::WhatsappCloudService.transient_send_retry_scheduled?(message) ||
      Whatsapp::Providers::WhatsappCloudService.delivery_outcome_unknown?(message) ||
      Whatsapp::Providers::Whatsapp360DialogService.delivery_outcome_unknown?(message)
  end

  def materialized_message_id(reminder)
    reminder.metadata.to_h[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY].to_s
  end

  def provider_appointment(reminder)
    return unless reminder.remindable_type == 'Scheduling::Appointment'

    reminder.remindable
  end

  def delivery_lock_key(reminder_id)
    format(Redis::Alfred::REMINDER_DELIVERY_MUTEX, reminder_id: reminder_id)
  end
end
