class Crm::Tasks::ReopenService < Crm::Tasks::CommandService
  private

  def event_type
    'task_reopened'
  end

  def no_op?
    !task.completed? && !task.cancelled?
  end

  def apply_command!
    @was_terminal = task.completed? || task.cancelled?
    clear_terminal_state! if @was_terminal
    transition_status!(default_open_status!)
  end

  def command_event_type(_before_data)
    @was_terminal ? event_type : 'task_status_changed'
  end

  def clear_terminal_state!
    task.task_outcome = nil
    task.outcome = nil
    task.outcome_note = nil
    task.completed_at = nil
    task.completed_by = nil
    task.cancelled_at = nil
    task.cancelled_by = nil
    task.cancellation_reason = nil
  end

  def default_open_status!
    return active_status_for!('open', allowed: %w[open in_progress]) if params[:status_id].present?

    account.crm_task_statuses.active.find_by(category: 'open', default: true) || active_status_for!('open')
  end
end
