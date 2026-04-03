class Captain::Tools::Copilot::GetTaskService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_task'
  end

  description 'Get details of a CRM task'
  param :task_id, type: :number, desc: 'The task ID', required: true

  def execute(task_id:)
    task = account.crm_tasks.includes(:status, :assignee, :team, :deal).find_by(id: task_id)
    return 'Task not found' if task.blank?

    formatted_record(task)
  end

  def active?
    feature_enabled?('crm_tasks') && (user_has_permission('crm_task_view') || user_has_permission('crm_task_manage'))
  end
end
