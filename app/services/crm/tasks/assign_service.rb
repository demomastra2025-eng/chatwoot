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
    @requested_assignee ||= begin
      assignee = resolve_optional_record(:assignee_id, account.users, current: task.assignee)
      Crm::Tasks::AssignmentAuthorizer.call(account: account, actor: actor, assignee: assignee, team: task.team)
      assignee
    end
  end
end
