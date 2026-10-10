class Reminders::DeliverMaterializedMessageJob < MutexApplicationJob
  queue_as :outbound_messages

  LOCK_TIMEOUT = 10.minutes
  UNCONFIRMED_PROVIDER_DELIVERY = 'Outbound provider did not confirm message submission'.freeze
  WHATSAPP_CHANNEL_TYPES = %w[Channel::Whatsapp Channel::WhatsappWeb].freeze

  discard_on ActiveRecord::RecordNotFound
  retry_on LockAcquisitionError, wait: 5.seconds, attempts: :unlimited
  retry_on Reminders::RetryableExecutionError, wait: 5.seconds, attempts: :unlimited

  def self.finalize_captain_follow_up_retry(message_id)
    new.send(:finalize_captain_follow_up_retry, message_id)
  end

  def self.schedule_captain_follow_up_after_retry(reminder_id, message_id)
    new.send(:schedule_confirmed_next_after_retry, reminder_id, message_id)
  end

  def perform(reminder_id, message_id, processing_claim)
    with_lock(delivery_lock_key(reminder_id), LOCK_TIMEOUT) do |renew_lock|
      dispatch!(reminder_id, message_id, processing_claim, renew_lock)
    end
  end

  private

  def dispatch!(reminder_id, message_id, processing_claim, renew_lock)
    reminder = Reminder.find(reminder_id)
    policy = Outbound::PlaygroundDeliveryPolicy.policy_for(reminder: reminder)
    unless policy.nil?
      outgoing = Message.outgoing.find_by!(id: message_id, account_id: reminder.account_id)
      Outbound::PlaygroundDeliveryPolicy.ensure!(conversation: outgoing.conversation, policy: policy)
    end
    provider_guard = Reminders::AppointmentProviderGuard.new(reminder: reminder, phase: :delivery)
    provider_check = [provider_guard, provider_guard.verify]
    raise LockAcquisitionError, 'Lost reminder delivery mutex before provider dispatch' unless renew_lock.call

    message = prepare_dispatch(reminder, message_id, processing_claim, provider_check)
    return schedule_confirmed_next_after_retry(reminder_id, message_id) if message.blank?

    if reminder.captain_follow_up?
      SendReplyJob.perform_now_with_follow_up_finalizer(message.id) do
        finalize_dispatch(reminder, message, processing_claim, schedule_next: false)
      end
      return schedule_confirmed_next_after_retry(reminder_id, message.id)
    end

    SendReplyJob.perform_now(message.id)
    finalize_dispatch(reminder, message, processing_claim)
  rescue Outbound::PlaygroundDeliveryPolicy::Blocked => e
    outgoing&.update!(status: :failed, external_error: e.message)
    reminder.with_lock { reminder.fail!(e.message, delivery_stage: 'failed') }
    false
  end

  def prepare_dispatch(reminder, message_id, processing_claim, provider_check)
    return prepare_captain_follow_up_dispatch(reminder, message_id, processing_claim, provider_check) if reminder.captain_follow_up?

    appointment = provider_appointment(reminder)
    return prepare_with_appointment_lock(appointment, reminder, message_id, processing_claim, provider_check) if appointment.present?

    prepare_with_reminder_lock(reminder, message_id, processing_claim, provider_check)
  end

  def prepare_captain_follow_up_dispatch(reminder, message_id, processing_claim, provider_check)
    records = captain_follow_up_records(reminder)
    unless records
      suppress_unpreparable_captain_follow_up!(reminder, message_id, processing_claim)
      return
    end

    conversation, assistant, anchor = records
    payload = { reminder: reminder, conversation: conversation, message_id: message_id,
                processing_claim: processing_claim, provider_check: provider_check,
                assistant: assistant, anchor: anchor }
    conversation.with_lock do
      conversation.reload
      conversation.with_captain_control_lock do
        conversation.reload
        reminder.with_lock do
          reminder.reload
          prepare_locked_captain_follow_up(payload)
        end
      end
    end
  end

  def prepare_locked_captain_follow_up(payload)
    reminder = payload[:reminder]
    return unless dispatchable?(reminder, payload[:message_id], payload[:processing_claim])

    message = Message.outgoing.find_by!(id: payload[:message_id], account_id: reminder.account_id)
    return unless message.additional_attributes.to_h['touch_id'].to_s == reminder.id.to_s

    unless captain_follow_up_current?(payload, message)
      suppress_stale_captain_follow_up!(reminder, message)
      return
    end
    return if provider_guard_stops?(*payload[:provider_check])

    message
  end

  def captain_follow_up_current?(payload, message)
    Captain::Conversation::FollowUpGuard.current?(
      reminder: payload[:reminder],
      conversation: payload[:conversation],
      assistant: payload[:assistant],
      anchor_message: payload[:anchor],
      message: message
    )
  end

  def suppress_unpreparable_captain_follow_up!(reminder, message_id, processing_claim)
    reason = 'Captain follow-up was canceled because a required record was removed before delivery'
    reminder.with_lock do
      reminder.reload
      next unless dispatchable?(reminder, message_id, processing_claim)
      next unless reminder.suppress_captain_follow_up_delivery!(message_id: message_id, reason: reason)

      fail_materialized_message_if_owned(reminder, message_id, reason)
    end
  end

  def fail_materialized_message_if_owned(reminder, message_id, reason)
    message = Message.outgoing.find_by(id: message_id, account_id: reminder.account_id)
    return unless message&.conversation_id == reminder.target_conversation_id
    return unless message.additional_attributes.to_h['touch_id'].to_s == reminder.id.to_s
    return if message.failed? || message.delivered? || message.read?

    message.update!(status: :failed, external_error: reason)
  end

  def captain_follow_up_records(reminder)
    metadata = reminder.metadata.to_h.deep_stringify_keys.fetch('captain_follow_up', {}).to_h
    conversation = Conversation.find_by(id: reminder.target_conversation_id, account_id: reminder.account_id)
    assistant = Captain::Assistant.find_by(id: metadata['assistant_id'], account_id: reminder.account_id)
    anchor = Message.find_by(id: metadata['anchor_message_id'], account_id: reminder.account_id)
    return unless conversation && assistant && anchor

    [conversation, assistant, anchor]
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

  def finalize_dispatch(reminder, message, processing_claim, schedule_next: true)
    message.reload
    return mark_failed_delivery(reminder, message, processing_claim) if message.failed?

    delivery_stage = delivery_handoff_stage(message)
    return mark_dispatched(reminder, message.id, processing_claim, delivery_stage, schedule_next: schedule_next) if delivery_stage.present?

    message.update!(status: :failed, external_error: UNCONFIRMED_PROVIDER_DELIVERY)
    mark_failed_delivery(reminder, message, processing_claim)
  end

  def mark_dispatched(reminder, message_id, processing_claim, delivery_stage, schedule_next: true)
    dispatched = reminder.with_lock do
      reminder.reload
      reminder.mark_delivery_dispatched!(message_id, stage: delivery_stage) if dispatchable?(reminder, message_id, processing_claim)
    end
    schedule_next_captain_follow_up(reminder, message_id) if schedule_next && dispatched && confirmed_delivery_stage?(delivery_stage)
    dispatched
  end

  def suppress_stale_captain_follow_up!(reminder, message)
    reason = 'Captain follow-up was canceled because conversation control changed before delivery'
    reminder.suppress_captain_follow_up_delivery!(message_id: message.id, reason: reason)
    message.update!(status: :failed, external_error: reason) unless message.failed? || message.delivered? || message.read?
  end

  def schedule_next_captain_follow_up(reminder, message_id)
    return unless reminder.captain_follow_up?

    message = Message.find_by(id: message_id, account_id: reminder.account_id)
    return unless message

    Captain::Conversation::FollowUpJob.schedule_after_delivery!(reminder: reminder, message: message)
  rescue *Reminders::ExecuteService::TRANSIENT_DATABASE_ERRORS => e
    Rails.logger.warn("[CAPTAIN][FollowUpJob] Retrying delivered next-step scheduling: #{e.class.name}")
    raise Reminders::RetryableExecutionError, 'Could not persist the next Captain follow-up step'
  end

  def finalize_captain_follow_up_retry(message_id)
    message = Message.find_by(id: message_id)
    return unless message&.outgoing?

    attributes = message.additional_attributes.to_h.deep_stringify_keys
    return unless attributes['captain_follow_up'].is_a?(Hash)

    reminder = Reminder.find_by(
      id: attributes['touch_id'],
      account_id: message.account_id,
      action_type: Reminder.action_types.fetch('captain_follow_up')
    )
    return unless reminder&.delivery_dispatched_for?(message.id)

    message.reload
    if message.failed?
      error = message.external_error.presence || UNCONFIRMED_PROVIDER_DELIVERY
      reminder.with_lock do
        reminder.reload
        reminder.fail!(error, delivery_stage: error.match?(/template|шаблон/i) ? 'template_rejected' : 'failed') if reminder.delivery_dispatched_for?(message.id)
      end
      return
    end

    delivery_stage = delivery_handoff_stage(message)
    if delivery_stage.present?
      reminder.with_lock do
        reminder.reload
        reminder.mark_delivery_dispatched!(message.id, stage: delivery_stage) if reminder.delivery_dispatched_for?(message.id)
      end
    else
      message.update!(status: :failed, external_error: UNCONFIRMED_PROVIDER_DELIVERY)
      reminder.with_lock do
        reminder.reload
        reminder.fail!(UNCONFIRMED_PROVIDER_DELIVERY, delivery_stage: 'failed') if reminder.delivery_dispatched_for?(message.id)
      end
    end
  end

  def schedule_confirmed_next_after_retry(reminder_id, message_id)
    reminder = Reminder.find_by(id: reminder_id)
    return unless reminder&.captain_follow_up? && reminder.delivery_dispatched_for?(message_id)
    return unless confirmed_delivery_stage?(reminder.delivery_stage)

    schedule_next_captain_follow_up(reminder, message_id)
  end

  def confirmed_delivery_stage?(delivery_stage)
    delivery_stage.in?(%w[provider_accepted delivered read])
  end

  def mark_failed_delivery(reminder, message, processing_claim)
    reminder.with_lock do
      reminder.reload
      next unless dispatchable?(reminder, message.id, processing_claim)

      error = message.external_error.presence || UNCONFIRMED_PROVIDER_DELIVERY
      delivery_stage = error.match?(/template|шаблон/i) ? 'template_rejected' : 'failed'
      reminder.fail!(error, delivery_stage: delivery_stage)
    end
  end

  def dispatchable?(reminder, message_id, processing_claim)
    (reminder.processing? || reminder.completed?) &&
      reminder.processing_claim_token == processing_claim &&
      materialized_message_id(reminder) == message_id.to_s &&
      !reminder.captain_follow_up_delivery_suppressed? &&
      !reminder.delivery_dispatched_for?(message_id)
  end

  def provider_guard_stops?(provider_guard, provider_verification)
    provider_guard.perform(verification: provider_verification) == Reminders::AppointmentProviderGuard::STOP
  end

  def delivery_handoff_stage(message)
    return 'provider_accepted' unless WHATSAPP_CHANNEL_TYPES.include?(message.inbox.channel_type)
    return 'provider_accepted' if message.source_id.present?
    return 'retry_scheduled' if Whatsapp::Providers::WhatsappCloudService.transient_send_retry_scheduled?(message)

    return 'provider_unknown' if Whatsapp::Providers::WhatsappCloudService.delivery_outcome_unknown?(message)
    return 'provider_unknown' if Whatsapp::Providers::Whatsapp360DialogService.delivery_outcome_unknown?(message)
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
