class Reminders::ExecutionLockService
  def initialize(reminder:, processing_claim:, execution_updated_at:)
    @reminder = reminder
    @processing_claim = processing_claim
    @execution_updated_at = execution_updated_at
  end

  def perform(&)
    result = nil
    lock_scope = -> { result = with_locked_execution(&) }

    if reminder.relative? && reminder.remindable.present? && !reminder.manual_schedule_override?
      reminder.remindable.with_lock(&lock_scope)
    else
      lock_scope.call
    end

    result
  end

  private

  attr_reader :reminder, :processing_claim, :execution_updated_at

  def with_locked_execution(&)
    result = nil
    reminder.with_lock do
      reminder.reload
      if reminder.processing? && current_execution_claim?
        result = if reminder.delivery_materialized?
                   Reminders::ExecutionFinisher.materialized_message_for(reminder)
                 elsif stale_execution?
                   reset_stale_execution!
                   nil
                 elsif execution_schedule_ready?
                   yield
                 end
      end
    end
    result
  end

  def current_execution_claim?
    reminder.processing_claim_token == processing_claim
  end

  def stale_execution?
    execution_updated_at.present? && reminder.updated_at != execution_updated_at
  end

  def reset_stale_execution!
    reminder.update!(status: :pending, processing_started_at: nil)
  end

  def execution_schedule_ready?
    Reminders::ExecutionScheduleGuard.new(reminder: reminder).perform == Reminders::ExecutionScheduleGuard::CONTINUE
  end
end
