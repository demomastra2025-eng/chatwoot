# frozen_string_literal: true

class Reminders::MissedAutomationTouchPolicy
  APPOINTMENT_ANCHORS = %w[appointment.starts_at appointment.ends_at].freeze
  CANCEL_REASON = 'missed_due_to_late_automation_event'
  GRACE_WINDOW = 5.minutes

  attr_reader :now, :reminder

  def initialize(reminder:, now: Time.current)
    @reminder = reminder
    @now = now
  end

  def cancel_if_missed!
    return false unless missed?

    reminder.with_lock do
      reminder.reload
      next false unless missed?

      cancelled_at = Time.current
      reminder.update!(
        status: :cancelled,
        cancelled_at: cancelled_at,
        processing_started_at: nil,
        last_error: CANCEL_REASON,
        metadata: reminder.metadata.to_h.merge(
          'cancelled_via' => 'missed_automation_schedule',
          'missed_schedule_cancelled_at' => cancelled_at.iso8601(6),
          'missed_schedule_original_scheduled_at' => reminder.scheduled_at.iso8601(6)
        )
      )
      log_cancellation
      true
    end
  end

  def missed?
    Reminder::OPEN_STATUSES.include?(reminder.status) &&
      !reminder.delivery_materialized? &&
      automation_touch? &&
      medelement_appointment_touch? &&
      reminder.scheduled_at.present? &&
      reminder.scheduled_at < now - GRACE_WINDOW
  end

  private

  def automation_touch?
    metadata = reminder.metadata.to_h
    metadata['touch_source'] == 'automation' || metadata[Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY] == 'automation'
  end

  def medelement_appointment_touch?
    appointment = reminder.remindable
    appointment.is_a?(Scheduling::Appointment) &&
      appointment.source == 'medelement' &&
      APPOINTMENT_ANCHORS.include?(reminder.relative_anchor)
  end

  def log_cancellation
    Rails.logger.info(
      event: 'missed_medelement_automation_touch_cancelled',
      account_id: reminder.account_id,
      reminder_id: reminder.id,
      appointment_id: reminder.remindable_id,
      scheduled_at: reminder.scheduled_at,
      evaluated_at: now
    )
  end
end
