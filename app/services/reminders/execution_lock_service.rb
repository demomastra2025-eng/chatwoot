class Reminders::ExecutionLockService
  STALE_AUTOMATION_GENERATION = 'automation_rule_inactive_or_stale_generation'.freeze

  def initialize(reminder:, processing_claim:, execution_updated_at:)
    @reminder = reminder
    @processing_claim = processing_claim
    @execution_updated_at = execution_updated_at
  end

  def perform(&)
    automation_rule_id = trusted_automation_rule_id
    return perform_with_execution_locks(&) if automation_rule_id.blank?

    AutomationRule.transaction do
      rule = AutomationRule.lock.find_by(id: automation_rule_id, account_id: reminder.account_id)
      unless current_automation_generation?(rule)
        reminder.cancel!(STALE_AUTOMATION_GENERATION)
        next
      end

      perform_with_execution_locks(&)
    end
  end

  private

  attr_reader :reminder, :processing_claim, :execution_updated_at

  def perform_with_execution_locks(&)
    result = nil
    lock_scope = -> { result = with_locked_execution(&) }

    if reminder.relative? && reminder.remindable.present? && !reminder.manual_schedule_override?
      reminder.remindable.with_lock(&lock_scope)
    else
      lock_scope.call
    end

    result
  end

  def trusted_automation_rule_id
    return unless reminder.metadata.to_h[Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY] == 'automation'

    reminder.metadata.to_h[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY]
  end

  def current_automation_generation?(rule)
    return false unless rule&.active?

    reminder_generation = reminder.metadata.to_h.fetch(Reminder::AUTOMATION_RULE_GENERATION_KEY, 1).to_i
    reminder_generation == rule.lifecycle_generation
  end

  def with_locked_execution(&)
    result = nil
    reminder.with_lock do
      reminder.reload
      result = locked_execution_result(&)
    end
    result
  end

  def locked_execution_result
    return unless executable_claim?
    return Reminders::ExecutionFinisher.materialized_message_for(reminder) if reminder.delivery_materialized?
    return reset_stale_execution! if stale_execution?
    return unless execution_schedule_ready?
    return reset_stale_execution! if refreshed_or_stale?

    yield
  end

  def executable_claim?
    reminder.processing? && current_execution_claim?
  end

  def refreshed_or_stale?
    @live_definition_refreshed || stale_execution?
  end

  def current_execution_claim?
    reminder.processing_claim_token == processing_claim
  end

  def stale_execution?
    execution_updated_at.present? && reminder.updated_at != execution_updated_at
  end

  def reset_stale_execution!
    reminder.update!(status: :pending, processing_started_at: nil)
    nil
  end

  def execution_schedule_ready?
    guard = Reminders::ExecutionScheduleGuard.new(reminder: reminder)
    result = guard.perform
    @live_definition_refreshed = guard.live_definition_refreshed?
    result == Reminders::ExecutionScheduleGuard::CONTINUE
  end
end
