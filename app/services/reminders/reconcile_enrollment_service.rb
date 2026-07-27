class Reminders::ReconcileEnrollmentService
  SOURCE_UNAVAILABLE = 'live touch source is disabled, deleted, or no longer contains the assigned action'.freeze
  STEP_REMOVED = 'live touch step was removed before delivery'.freeze

  attr_reader :enrollment

  def initialize(enrollment:)
    @enrollment = enrollment
  end

  def perform
    enrollment.with_lock do
      enrollment.reload
      next enrollment if enrollment.cancelled?

      if definition_resolver.source_available?
        reconcile_materialized_reminders!
        schedule.refresh_next_due!
      else
        cancel_unavailable_source!
      end
      enrollment
    end
  end

  private

  def reconcile_materialized_reminders!
    steps = schedule.current_steps.index_by(&:step_key)

    enrollment.touch_occurrence_claims.includes(:reminder).find_each do |claim|
      reminder = claim.reminder
      next if reminder.blank? || Reminder::OPEN_STATUSES.exclude?(reminder.status) || reminder.delivery_materialized?

      step = steps[claim.step_key]
      if step.blank?
        cancel_materialized!(claim, reminder, STEP_REMOVED)
      else
        Reminders::SyncMaterializedEnrollmentReminderService.new(
          enrollment: enrollment,
          claim: claim,
          reminder: reminder,
          step: step
        ).perform
      end
    end
  end

  def cancel_unavailable_source!
    Reminders::CancelEnrollmentService.new(
      enrollment: enrollment,
      reason: 'live_source_unavailable',
      metadata: { 'source_error' => SOURCE_UNAVAILABLE }
    ).perform
  end

  def cancel_materialized!(claim, reminder, reason)
    reminder.cancel!(reason)
    claim.update!(status: 'skipped', last_error: reason) if reminder.reload.cancelled?
  end

  def schedule
    @schedule ||= Reminders::EnrollmentScheduleService.new(enrollment: enrollment)
  end

  def definition_resolver
    @definition_resolver ||= Reminders::EnrollmentDefinitionResolver.new(enrollment: enrollment)
  end
end
