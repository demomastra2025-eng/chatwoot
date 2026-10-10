module Reminders::MaterializedFollowUpRetry
  private

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

    finalize_retried_delivery(reminder, message)
  end

  def finalize_retried_delivery(reminder, message)
    message.reload
    if message.failed?
      error = message.external_error.presence || Reminders::DeliverMaterializedMessageJob::UNCONFIRMED_PROVIDER_DELIVERY
      fail_dispatched_retry(reminder, message, error)
      return
    end

    delivery_stage = delivery_handoff_stage(message)
    return mark_dispatched_retry(reminder, message, delivery_stage) if delivery_stage.present?

    error = Reminders::DeliverMaterializedMessageJob::UNCONFIRMED_PROVIDER_DELIVERY
    message.update!(status: :failed, external_error: error)
    fail_dispatched_retry(reminder, message, error, delivery_stage: 'failed')
  end

  def mark_dispatched_retry(reminder, message, delivery_stage)
    reminder.with_lock do
      reminder.reload
      reminder.mark_delivery_dispatched!(message.id, stage: delivery_stage) if reminder.delivery_dispatched_for?(message.id)
    end
  end

  def fail_dispatched_retry(reminder, message, error, delivery_stage: nil)
    reminder.with_lock do
      reminder.reload
      next unless reminder.delivery_dispatched_for?(message.id)

      delivery_stage ||= error.match?(/template|шаблон/i) ? 'template_rejected' : 'failed'
      reminder.fail!(error, delivery_stage: delivery_stage)
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
end
