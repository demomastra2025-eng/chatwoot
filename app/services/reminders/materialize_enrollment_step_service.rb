class Reminders::MaterializeEnrollmentStepService
  GRACE_WINDOW = Reminders::MissedAutomationTouchPolicy::GRACE_WINDOW

  attr_reader :enrollment, :now

  def initialize(enrollment:, now: Time.current)
    @enrollment = enrollment
    @now = now
  end

  def perform
    enrollment.with_lock(requires_new: true) do
      enrollment.reload
      process_locked_enrollment
    end
  rescue ActiveRecord::RecordNotUnique => e
    duplicate_claim = enrollment.touch_occurrence_claims.find_by(occurrence_key: @occurrence_key)
    return duplicate_claim if duplicate_claim.present?

    raise e
  end

  private

  def feature_enabled?
    enrollment.account.feature_enabled?(Reminders::DeferredMaterializationPolicy::FEATURE_NAME)
  end

  def process_locked_enrollment
    return process_inactive_enrollment unless enrollment.active?
    return pause_enrollment! unless feature_enabled?
    return cancel_unusable_source! unless source_usable?
    return if Reminders::AppointmentShortLeadCancellation.cancel_enrollment_if_short!(enrollment, now: now)

    schedule = Reminders::EnrollmentScheduleService.new(enrollment: enrollment)
    return cancel_terminal!(schedule) if schedule.terminal_remindable?

    process_schedule(schedule)
  end

  def process_schedule(schedule)
    step = schedule.next_step
    return complete_enrollment! if step.blank?
    return reschedule_enrollment!(step) if step.due_at > now
    return skip_missed!(step, schedule) if missed_step?(step)

    materialize!(step, schedule)
  end

  def missed_step?(step)
    return true if step.due_at < now - GRACE_WINDOW
    return false unless enrollment.automation_rule_id.present? && enrollment.remindable.is_a?(Scheduling::Appointment)

    probe = Reminders::RelativeScheduleProbe.new(
      account: enrollment.account, remindable: enrollment.remindable,
      definition: step.definition, created_at: enrollment.activated_at
    )
    Reminders::MissedAutomationTouchPolicy.new(reminder: probe.reminder, now: now).missed?
  end

  def process_inactive_enrollment
    resume_feature_paused! if feature_paused?
  end

  def pause_enrollment!
    enrollment.update!(
      status: 'paused',
      metadata: enrollment.metadata.merge(
        'paused_reason' => Reminders::DeferredMaterializationPolicy::FEATURE_NAME,
        'paused_at' => now.iso8601
      )
    )
  end

  def feature_paused?
    enrollment.paused? &&
      enrollment.metadata['paused_reason'] == Reminders::DeferredMaterializationPolicy::FEATURE_NAME
  end

  def resume_feature_paused!
    return unless feature_enabled?

    enrollment.update!(
      status: 'active',
      metadata: enrollment.metadata.except('paused_reason', 'paused_at')
    )
    process_locked_enrollment
  end

  def cancel_terminal!(schedule)
    enrollment.cancel!(reason: 'remindable_terminal', metadata: { evaluated_at: now.iso8601 })
    schedule
  end

  def complete_enrollment!
    enrollment.update!(status: 'completed', next_due_at: nil)
    nil
  end

  def reschedule_enrollment!(step)
    enrollment.update!(next_due_at: step.due_at)
    nil
  end

  def skip_missed!(step, schedule)
    claim = create_claim!(step, status: 'skipped', last_error: 'missed_due_to_reschedule')
    schedule.refresh_next_due!
    claim
  end

  def materialize!(step, schedule)
    claim = create_claim!(step)
    reminder = Reminders::CreateService.new(
      account: enrollment.account,
      remindable: enrollment.remindable,
      reminder_group: enrollment.reminder_group,
      creator: enrollment_creator,
      attributes: reminder_attributes(step, claim)
    ).perform
    apply_automation_provenance!(reminder)
    Reminders::SyncRemindableService.new(remindable: enrollment.remindable).perform
    approve_resolved_reminder!(reminder)
    Reminders::CampaignConflictPolicy.new(reminder: reminder).cancel_if_conflict!
    claim.update!(status: 'materialized', reminder: reminder, materialized_at: now)
    schedule.refresh_next_due!
    claim
  end

  def create_claim!(step, status: 'claimed', last_error: nil)
    @occurrence_key = step.occurrence_key
    enrollment.touch_occurrence_claims.create!(
      account: enrollment.account,
      step_key: step.step_key,
      occurrence_key: step.occurrence_key,
      due_at: step.due_at,
      status: status,
      claimed_at: now,
      last_error: last_error,
      metadata: { 'scheduler_lag_seconds' => [(now - step.due_at).to_i, 0].max }
    )
  end

  def reminder_attributes(step, claim)
    Reminders::EnrollmentReminderAttributes.new(enrollment: enrollment, step: step, claim: claim).call
  end

  def approve_resolved_reminder!(reminder)
    reminder.reload
    reminder.approve! if reminder.draft? && reminder.ready_for_pending?
  end

  def enrollment_creator
    return unless enrollment.metadata['actor_type'] == 'User'

    enrollment.account.users.find_by(id: enrollment.metadata['actor_id'])
  end

  def apply_automation_provenance!(reminder)
    return unless enrollment.automation_rule.present? || enrollment.metadata['actor_type'] == 'AutomationRule'

    rule = enrollment.automation_rule || AutomationRule.find_by(id: enrollment.metadata['actor_id'], account_id: enrollment.account_id)
    reminder.mark_automation_provenance!(rule) if rule.present?
  end

  # The live source still exists, its rule does not exclude a contact of the record, and no contact of the record is muted/blocked.
  def source_usable?
    definition_resolver.source_available? &&
      !Reminders::ExcludedContactPolicy.enrollment_excluded?(enrollment) &&
      !contact_notifications_suppressed?
  end

  def cancel_unusable_source!
    return cancel_unavailable_source! unless definition_resolver.source_available?
    return cancel_excluded_contact! if Reminders::ExcludedContactPolicy.enrollment_excluded?(enrollment)

    cancel_suppressed_contact!
  end

  def contact_notifications_suppressed?
    Contact.automation_notifications_suppressed_for?(enrollment.remindable, account_id: enrollment.account_id)
  end

  def cancel_suppressed_contact!
    Reminders::SuppressedContactPolicy.cancel_enrollment_if_suppressed!(
      enrollment,
      extra_metadata: { 'evaluated_at' => now.iso8601 }
    )
  end

  def cancel_unavailable_source!
    enrollment.cancel!(reason: 'live_source_unavailable', metadata: { evaluated_at: now.iso8601 })
  end

  # The rule excludes a contact of the enrollment's record (it may have been edited after the enrollment was made):
  # no step is materialized and the ones that exist but were not delivered are cancelled with the enrollment.
  def cancel_excluded_contact!
    Reminders::CancelEnrollmentService.new(
      enrollment: enrollment,
      reason: Reminders::ExcludedContactPolicy::CANCEL_REASON,
      metadata: { 'evaluated_at' => now.iso8601, 'cancelled_via' => Reminders::ExcludedContactPolicy::CANCELLED_VIA }
    ).perform
  end

  def definition_resolver
    @definition_resolver ||= Reminders::EnrollmentDefinitionResolver.new(enrollment: enrollment)
  end
end
