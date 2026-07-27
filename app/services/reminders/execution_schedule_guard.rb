class Reminders::ExecutionScheduleGuard
  CONTINUE = :continue
  STOP = :stop
  MISSED_RELATIVE_SCHEDULE = 'Skipped relative touch because its scheduled time had already passed when it was created.'.freeze
  INVALID_DEFERRED_ENROLLMENT = 'Skipped deferred touch because its enrollment or source entity is no longer active.'.freeze
  DEFERRED_GRACE_WINDOW = 5.minutes

  def initialize(reminder:)
    @reminder = reminder
  end

  def perform
    sync_live_definition!
    return stop_for_invalid_deferred_enrollment! if invalid_deferred_enrollment?
    return CONTINUE unless refreshable?

    reminder.remindable.reload
    refresh_schedule_if_anchor_changed!
    return stop_for_missed_schedule! if missed_relative_schedule?
    return stop_for_rescheduled_touch! if reminder.scheduled_at&.future?

    CONTINUE
  end

  def live_definition_refreshed?
    @live_definition_refreshed == true
  end

  private

  attr_reader :reminder

  def refreshable?
    reminder.relative? && reminder.remindable.present? && !reminder.manual_schedule_override?
  end

  def refresh_schedule_if_anchor_changed!
    anchor_time = reminder.send(:relative_anchor_time)
    return if same_time?(anchor_time, reminder.last_materialized_anchor_at)

    reminder.save!
  end

  def missed_relative_schedule?
    return reminder.scheduled_at < Time.current - DEFERRED_GRACE_WINDOW if deferred_enrollment? && reminder.scheduled_at.present?

    reminder.scheduled_at.present? && reminder.created_at.present? && reminder.scheduled_at < reminder.created_at
  end

  def invalid_deferred_enrollment?
    return false unless deferred_enrollment?
    return true if deferred_enrollment.blank?

    [
      invalid_deferred_status?,
      completed_without_current_claim?,
      !deferred_source_available?,
      deferred_step.blank?,
      deferred_terminal_remindable?
    ].any?
  end

  def sync_live_definition!
    return unless deferred_enrollment?
    return if deferred_enrollment.blank? || invalid_deferred_status?
    return unless deferred_source_available?
    return if deferred_step.blank? || deferred_claim.blank?

    attributes_before_sync = reminder.attributes.except('updated_at')
    Reminders::SyncMaterializedEnrollmentReminderService.new(
      enrollment: deferred_enrollment,
      claim: deferred_claim,
      reminder: reminder,
      step: deferred_step,
      lock: false
    ).perform
    reminder.reload
    @live_definition_refreshed = attributes_before_sync != reminder.attributes.except('updated_at')
  end

  def deferred_source_available?
    Reminders::EnrollmentDefinitionResolver.new(enrollment: deferred_enrollment).source_available?
  end

  def deferred_step
    return @deferred_step if defined?(@deferred_step)

    steps = Reminders::EnrollmentScheduleService.new(enrollment: deferred_enrollment).current_steps
    @deferred_step = steps.find { |step| step.step_key == deferred_claim&.step_key }
  end

  def invalid_deferred_status?
    deferred_enrollment.cancelled? ||
      (deferred_enrollment.paused? && !feature_paused_materialized_claim?)
  end

  def completed_without_current_claim?
    deferred_enrollment.completed? && !current_materialized_claim?
  end

  def deferred_terminal_remindable?
    Reminders::EnrollmentScheduleService.new(enrollment: deferred_enrollment).terminal_remindable?
  end

  def current_materialized_claim?
    deferred_claim&.materialized? && deferred_claim.reminder_id == reminder.id
  end

  def feature_paused_materialized_claim?
    deferred_enrollment.metadata['paused_reason'] == Reminders::DeferredMaterializationPolicy::FEATURE_NAME &&
      current_materialized_claim?
  end

  def deferred_enrollment?
    reminder.metadata.to_h['touch_plan_enrollment_id'].present?
  end

  def deferred_enrollment
    return @deferred_enrollment if defined?(@deferred_enrollment)

    @deferred_enrollment = reminder.account.touch_plan_enrollments.find_by(
      id: reminder.metadata.to_h['touch_plan_enrollment_id']
    )
  end

  def stop_for_invalid_deferred_enrollment!
    cancel_reminder!(INVALID_DEFERRED_ENROLLMENT)
    STOP
  end

  def stop_for_missed_schedule!
    cancel_reminder!(MISSED_RELATIVE_SCHEDULE)
    STOP
  end

  def cancel_reminder!(reason)
    reminder.update!(
      status: :cancelled,
      cancelled_at: Time.current,
      processing_started_at: nil,
      last_error: reason
    )
    deferred_claim&.update!(status: 'skipped', last_error: reason)
  end

  def deferred_claim
    claim_id = reminder.metadata.to_h['touch_occurrence_claim_id']
    reminder.account.touch_occurrence_claims.find_by(id: claim_id) if claim_id.present?
  end

  def stop_for_rescheduled_touch!
    reminder.update!(status: :pending, processing_started_at: nil)
    STOP
  end

  def same_time?(left, right)
    return true if left.blank? && right.blank?

    left.present? && right.present? && left.to_i == right.to_i
  end
end
