class Reminders::ExecutionLockService
  def initialize(reminder:, processing_claim:, execution_updated_at:)
    @reminder = reminder
    @processing_claim = processing_claim
    @execution_updated_at = execution_updated_at
  end

  def perform(&)
    result = nil
    lock_scope = -> { result = with_locked_execution(&) }

    if lock_remindable?
      reminder.remindable.with_lock(&lock_scope)
    else
      lock_scope.call
    end

    result
  end

  private

  attr_reader :reminder, :processing_claim, :execution_updated_at

  def lock_remindable?
    return false if reminder.remindable.blank?
    return true if reminder.remindable_type == 'Scheduling::Appointment'

    reminder.relative? && !reminder.manual_schedule_override?
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
