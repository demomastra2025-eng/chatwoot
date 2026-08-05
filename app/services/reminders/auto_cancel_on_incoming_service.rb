# frozen_string_literal: true

class Reminders::AutoCancelOnIncomingService
  CANCELLED_AFTER_INCOMING_REPLY = Reminders::IncomingReplyCancellationService::CANCEL_REASON

  attr_reader :event_timestamp, :message

  def initialize(message:, event_timestamp: nil)
    @message = message
    @event_timestamp = event_timestamp || message&.created_at || Time.current
  end

  def perform
    return 0 unless Reminders::IncomingReplyCancellationService.customer_incoming_message?(message)

    cancel_materialized_reminders! + cancel_deferred_steps!
  end

  private

  def cancel_materialized_reminders!
    cancelled_count = 0
    cancellable_scope.find_each do |reminder|
      next unless reminder_precedes_message?(reminder)

      cancelled_count += 1 if cancel_reminder!(reminder)
    end
    cancelled_count
  end

  def cancellable_scope
    conversation = message.conversation
    message.account.reminders
           .open_statuses
           .where(auto_cancel_on_incoming: true)
           .where(
             <<~SQL.squish,
               conversation_id = :conversation_id OR
               target_conversation_id = :conversation_id OR
               (remindable_type = :conversation_type AND remindable_id = :conversation_id) OR
               (target_contact_id = :contact_id AND remindable_type IN (:live_entity_types))
             SQL
             conversation_id: conversation.id,
             conversation_type: 'Conversation',
             contact_id: message.sender_id,
             live_entity_types: TouchPlanEnrollment::SUPPORTED_REMINDABLE_TYPES
           )
  end

  def cancel_deferred_steps!
    skipped_count = 0
    deferred_enrollment_scope.find_each do |enrollment|
      enrollment.with_lock do
        enrollment.reload
        next if enrollment.cancelled?

        skipped_count += cancel_materialized_enrollment_reminders!(enrollment)
        next unless enrollment.active? || enrollment.paused?

        schedule = Reminders::EnrollmentScheduleService.new(enrollment: enrollment)
        schedule.pending_steps.each do |step|
          next unless Reminders::BooleanParam.truthy?(step.definition.to_h['auto_cancel_on_incoming'])

          create_skipped_claim!(enrollment, step)
          skipped_count += 1
        rescue ActiveRecord::RecordNotUnique
          next
        end
        schedule.refresh_next_due!
      end
    end
    skipped_count
  end

  def cancel_materialized_enrollment_reminders!(enrollment)
    enrollment.touch_occurrence_claims.includes(:reminder).sum do |claim|
      reminder = claim.reminder
      next 0 unless cancellable_reminder?(reminder)

      cancel_reminder!(reminder) ? 1 : 0
    end
  end

  def cancellable_reminder?(reminder)
    reminder.present? &&
      Reminder::OPEN_STATUSES.include?(reminder.status) &&
      !reminder.delivery_materialized? &&
      explicitly_auto_cancelled?(reminder)
  end

  def cancel_reminder!(reminder)
    Reminders::IncomingReplyCancellationService.new(reminder: reminder, message: message).perform
  end

  def create_skipped_claim!(enrollment, step)
    enrollment.touch_occurrence_claims.create!(
      account: enrollment.account,
      step_key: step.step_key,
      occurrence_key: step.occurrence_key,
      due_at: step.due_at,
      status: 'skipped',
      claimed_at: Time.current,
      last_error: CANCELLED_AFTER_INCOMING_REPLY,
      metadata: { 'incoming_message_id' => message.id }
    )
  end

  def deferred_enrollment_scope
    appointment_ids = Scheduling::Appointment.where(account_id: message.account_id, contact_id: message.sender_id).select(:id)
    deal_ids = Crm::Deal.joins(:deal_contacts)
                        .where(account_id: message.account_id, crm_deal_contacts: { contact_id: message.sender_id })
                        .select(:id)

    message.account.touch_plan_enrollments
           .where(status: %w[active paused completed])
           .where('touch_plan_enrollments.created_at < ?', event_timestamp)
           .where(
             <<~SQL.squish,
               (remindable_type = :appointment_type AND remindable_id IN (:appointment_ids)) OR
               (remindable_type = :deal_type AND remindable_id IN (:deal_ids))
             SQL
             appointment_type: 'Scheduling::Appointment',
             appointment_ids: appointment_ids,
             deal_type: 'Crm::Deal',
             deal_ids: deal_ids
           )
  end

  def explicitly_auto_cancelled?(reminder)
    Reminders::BooleanParam.truthy?(reminder.metadata.to_h['auto_cancel_on_incoming_explicit'])
  end

  def reminder_precedes_message?(reminder)
    trigger_message_id = automation_trigger_message_id(reminder)
    return trigger_message_id < message.id if trigger_message_id.present?

    reminder.created_at < event_timestamp
  end

  def automation_trigger_message_id(reminder)
    Integer(reminder.metadata.to_h[Reminder::AUTOMATION_TRIGGER_MESSAGE_ID_KEY])
  rescue ArgumentError, TypeError
    nil
  end
end
