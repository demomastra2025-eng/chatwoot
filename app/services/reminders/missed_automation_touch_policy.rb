# frozen_string_literal: true

class Reminders::MissedAutomationTouchPolicy
  APPOINTMENT_ANCHORS = %w[appointment.starts_at appointment.ends_at].freeze
  CANCEL_REASON = 'missed_due_to_late_automation_event'
  GRACE_WINDOW = 5.minutes
  STARTED_REASON = 'appointment_started'
  CLOSED_REASON = 'appointment_closed'

  attr_reader :now, :reminder

  def initialize(reminder:, now: Time.current)
    @reminder = reminder
    @now = now
  end

  def cancel_if_missed!
    return false unless skip_reason

    reminder.with_lock do
      reminder.reload
      reason = skip_reason
      next false unless reason

      cancel_reminder!(reason)
      skip_claim!(reason)
      log_cancellation
      true
    end
  end

  def missed?
    skip_reason.present?
  end

  def skip_reason
    return unless Reminder::OPEN_STATUSES.include?(reminder.status) && !reminder.delivery_materialized?
    return unless automation_visit_touch?

    return CLOSED_REASON if closed_before_visit?
    return CANCEL_REASON if late?

    STARTED_REASON if started_before_visit?
  end

  def automation_visit_touch?
    automation_touch? && appointment_touch?
  end

  # Only the provider guard writes this protected marker, after an eligible execution.
  # Without a manual override, a claim rematerializes the relative due time and increments its revision once.
  def runtime_retry_metadata(schedule_revision:)
    return unless automation_visit_touch? && !missed?

    { 'snapshot' => runtime_retry_snapshot, 'schedule_revision' => schedule_revision }
  end

  def delivery_retry_skip_reason
    return unless automation_visit_touch?

    return CLOSED_REASON if closed_before_visit?
    return STARTED_REASON if started_before_visit?
    return if reminder.metadata.to_h[Reminder::APPOINTMENT_PROVIDER_RETRY_KEY].blank?
    return CANCEL_REASON if late?
    return if runtime_retry?

    'appointment_changed_during_provider_retry'
  end

  private

  def cancel_reminder!(reason)
    cancelled_at = Time.current
    reminder.update!(
      status: :cancelled, cancelled_at: cancelled_at, processing_started_at: nil, last_error: reason,
      metadata: reminder.metadata.to_h.merge(
        'cancelled_via' => 'missed_automation_schedule',
        'missed_schedule_cancelled_at' => cancelled_at.iso8601(6),
        'missed_schedule_original_scheduled_at' => reminder.scheduled_at&.iso8601(6)
      )
    )
  end

  def skip_claim!(reason)
    claim_id = reminder.metadata.to_h['touch_occurrence_claim_id']
    return if claim_id.blank?

    reminder.account.touch_occurrence_claims.find_by(id: claim_id)&.update!(status: 'skipped', last_error: reason)
  end

  def automation_touch?
    metadata = reminder.metadata.to_h
    metadata['touch_source'] == 'automation' || metadata[Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY] == 'automation'
  end

  def appointment_touch?
    appointment = reminder.remindable
    reminder.relative? && appointment.is_a?(Scheduling::Appointment) &&
      APPOINTMENT_ANCHORS.include?(reminder.relative_anchor)
  end

  def recomputed_due_at
    Reminders::RelativeScheduleProbe.new(
      account: reminder.account, remindable: reminder.remindable, created_at: reminder.created_at,
      definition: reminder.attributes.slice(
        'timing_mode', 'relative_anchor', 'relative_offset_seconds', 'relative_time_mode', 'relative_time_of_day', 'timezone'
      )
    ).due_at
  end

  def before_visit?
    reminder.relative_anchor == 'appointment.starts_at' && reminder.relative_offset_seconds.to_i.negative?
  end

  def closed_before_visit?
    before_visit? && reminder.remindable.status.in?(%w[completed no_show cancelled])
  end

  def late?
    due_at = recomputed_due_at
    !(before_visit? && runtime_retry?) && due_at.present? && due_at < now - GRACE_WINDOW
  end

  def started_before_visit?
    before_visit? && reminder.remindable.starts_at <= now
  end

  def runtime_retry?
    marker = reminder.metadata.to_h[Reminder::APPOINTMENT_PROVIDER_RETRY_KEY]
    return false unless marker.is_a?(Hash)

    revision = reminder.schedule_revision.to_i + (reminder.pending? && !reminder.manual_schedule_override? ? 1 : 0)
    marker['schedule_revision'] == revision && marker['snapshot'] == runtime_retry_snapshot
  end

  def runtime_retry_snapshot
    {
      'reminder_id' => reminder.id,
      'appointment_id' => reminder.remindable_id,
      'appointment' => reminder.remindable.attributes.slice(
        'starts_at', 'ends_at', 'resource_id', 'contact_id', 'patient_contact_id', 'source', 'external_ref'
      ).as_json,
      'definition' => reminder.attributes.slice(
        'timing_mode', 'relative_anchor', 'relative_offset_seconds', 'relative_time_mode',
        'relative_time_of_day', 'timezone', 'manual_schedule_override'
      )
    }
  end

  def log_cancellation
    Rails.logger.info(
      event: 'missed_automation_touch_cancelled',
      account_id: reminder.account_id,
      reminder_id: reminder.id,
      appointment_id: reminder.remindable_id,
      scheduled_at: reminder.scheduled_at,
      evaluated_at: now
    )
  end
end
