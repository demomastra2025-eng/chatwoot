class Reminders::MaterializeEnrollmentStepService
  GRACE_WINDOW = 5.minutes

  attr_reader :enrollment, :now

  def initialize(enrollment:, now: Time.current)
    @enrollment = enrollment
    @now = now
  end

  def perform
    enrollment.with_lock do
      enrollment.reload
      process_locked_enrollment
    end
  rescue ActiveRecord::RecordNotUnique
    enrollment.touch_occurrence_claims.find_by(occurrence_key: @occurrence_key)
  end

  private

  def feature_enabled?
    enrollment.account.feature_enabled?(Reminders::DeferredMaterializationPolicy::FEATURE_NAME)
  end

  def process_locked_enrollment
    return process_inactive_enrollment unless enrollment.active?
    return pause_enrollment! unless feature_enabled?

    schedule = Reminders::EnrollmentScheduleService.new(enrollment: enrollment)
    return cancel_terminal!(schedule) if schedule.terminal_remindable?

    step = schedule.next_step
    return complete_enrollment! if step.blank?
    return reschedule_enrollment!(step) if step.due_at > now
    return skip_missed!(step, schedule) if step.due_at < now - GRACE_WINDOW

    materialize!(step, schedule)
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
    step.definition.with_indifferent_access.merge(
      metadata: step.definition.to_h.fetch('metadata', {}).to_h.merge(
        'touch_source' => enrollment.metadata['touch_source'],
        'touch_plan_enrollment_id' => enrollment.id,
        'touch_occurrence_claim_id' => claim.id,
        'touch_occurrence_key' => claim.occurrence_key
      ).compact
    )
  end

  def enrollment_creator
    return unless enrollment.metadata['actor_type'] == 'User'

    enrollment.account.users.find_by(id: enrollment.metadata['actor_id'])
  end

  def apply_automation_provenance!(reminder)
    return unless enrollment.metadata['actor_type'] == 'AutomationRule'

    rule = AutomationRule.find_by(id: enrollment.metadata['actor_id'], account_id: enrollment.account_id)
    reminder.mark_automation_provenance!(rule) if rule.present?
  end
end
