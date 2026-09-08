class Crm::Tasks::AssignService < Crm::Tasks::CommandService
  private

  def event_type
    'task_assigned'
  end

  def no_op?
    requested_assignee == task.assignee
  end

  def apply_command!
    task.assignee = requested_assignee
  end

  def after_save!
    super
    Crm::AssignmentNotificationService.new(
      account: account,
      record: task,
      user: task.assignee,
      notification_type: 'task_assignment',
      actor: actor
    ).perform
  end

  def requested_assignee
    @requested_assignee ||= resolve_optional_record(:assignee_id, account.users, current: task.assignee)
  end
end
