# frozen_string_literal: true

# An appointment notice made by an automation rule on «запись создана» or «запись перенесена» is cancelled instead of
# sent when it can only confuse the patient:
#   - the visit has already started (a MedElement sync miss imported the reception late, or the notice waited too long);
#   - the action opted in with metadata.skip_if_imported_late and the MedElement reception reached OneLink more than an
#     hour after it was created there (appointment_created only).
# Only a text message sent once and soon after the event is a notice. Touches timed from the visit itself
# (appointment.starts_at / ends_at, e.g. «за 2 часа»), follow-ups planned later than an hour after the event, repeating
# series and AI wake-ups are not; a late visit-timed touch is handled by Reminders::MissedAutomationTouchPolicy.
class Reminders::StaleAppointmentNoticePolicy
  NOTICE_EVENT_NAMES = %w[appointment_created appointment_rescheduled].freeze
  VISIT_ANCHORS = Reminders::MissedAutomationTouchPolicy::APPOINTMENT_ANCHORS
  LATE_IMPORT_OPT_IN_KEY = 'skip_if_imported_late'
  MAX_IMPORT_LAG = 1.hour
  MAX_NOTICE_DELAY = 1.hour
  STARTED_REASON = 'appointment_notice_after_start'
  LATE_IMPORT_REASON = 'appointment_notice_late_import'
  CANCELLED_VIA = 'stale_appointment_notice'
  UNSCOPED_PROCESSING_CLAIM = Object.new.freeze

  attr_reader :now, :processing_claim, :reminder

  # processing_claim: pass the claim of the execution that is about to send the touch, then only that execution's
  # processing touch can be cancelled; without it any open touch can.
  def initialize(reminder:, now: Time.current, processing_claim: UNSCOPED_PROCESSING_CLAIM)
    @reminder = reminder
    @now = now
    @execution_scoped = !processing_claim.equal?(UNSCOPED_PROCESSING_CLAIM)
    @processing_claim = @execution_scoped ? processing_claim : nil
  end

  def cancel_if_stale!
    return false unless reminder.persisted? && stale_reason.present?

    reminder.with_lock do
      reminder.reload
      reason = stale_reason
      next false if reason.blank?

      cancel!(reason)
      true
    end
  end

  def stale_reason
    return unless notice?
    return STARTED_REASON if appointment.starts_at.present? && appointment.starts_at <= now && prompt_notice?

    LATE_IMPORT_REASON if late_import?
  end

  private

  def notice?
    cancellable_state? && automation_notice? && appointment.present? && !visit_timed?
  end

  def cancellable_state?
    return false if reminder.delivery_materialized?
    return Reminder::OPEN_STATUSES.include?(reminder.status) unless @execution_scoped

    reminder.processing? && reminder.processing_claim_token == processing_claim
  end

  def automation_notice?
    reminder.send_message? && reminder.once? && automation_touch? &&
      NOTICE_EVENT_NAMES.include?(metadata[Reminder::AUTOMATION_EVENT_NAME_KEY].to_s)
  end

  def automation_touch?
    metadata['touch_source'] == 'automation' || metadata[Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY] == 'automation'
  end

  def visit_timed?
    reminder.relative? && VISIT_ANCHORS.include?(reminder.relative_anchor.to_s)
  end

  # A notice goes out right after the event; a message planned for days later is a follow-up, not a notice.
  def prompt_notice?
    reminder.scheduled_at.blank? || reminder.scheduled_at - event_time <= MAX_NOTICE_DELAY
  end

  def event_time
    anchor = reminder.relative_anchor.to_s == 'appointment.created_at' ? appointment.created_at : reminder.created_at
    anchor || now
  end

  def late_import?
    return false unless metadata[Reminder::AUTOMATION_EVENT_NAME_KEY] == 'appointment_created'
    return false unless Reminders::BooleanParam.truthy?(metadata[LATE_IMPORT_OPT_IN_KEY])
    return false unless medelement_appointment? && appointment.created_at.present?

    source_created_at = Crm::Appointments::SourceCreationTime.for(appointment)
    source_created_at.present? && appointment.created_at - source_created_at > MAX_IMPORT_LAG
  end

  def medelement_appointment?
    appointment.source == 'medelement' || appointment.external_ref.to_s.start_with?('medelement:reception:')
  end

  def appointment
    reminder.remindable if reminder.remindable.is_a?(Scheduling::Appointment)
  end

  def metadata
    reminder.metadata.to_h
  end

  def cancel!(reason)
    cancelled_at = Time.current
    reminder.update!(
      status: :cancelled,
      cancelled_at: cancelled_at,
      processing_started_at: nil,
      last_error: reason,
      metadata: metadata.merge('cancelled_via' => CANCELLED_VIA, 'stale_notice_cancelled_at' => cancelled_at.iso8601(6))
    )
    Rails.logger.info(
      event: 'stale_appointment_notice_cancelled',
      account_id: reminder.account_id,
      reminder_id: reminder.id,
      appointment_id: reminder.remindable_id,
      reason: reason
    )
  end
end
