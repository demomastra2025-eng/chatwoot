class Captain::Tools::Copilot::GetTaskTimelineService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_task_timeline'
  end

  description 'Get the timeline for a CRM task'
  param :task_id, type: :number, desc: 'The task ID', required: true
  param :limit, type: :number, desc: 'Maximum number of timeline items', required: false

  def execute(task_id:, limit: nil)
    task = account.crm_tasks.find_by(id: task_id)
    return 'Task not found' if task.blank?

    timeline = ::Crm::Timelines::TaskService.new(
      account: account,
      task: task,
      actor: @user,
      params: { limit: limit }.compact
    ).perform

    formatted_payload(
      task_id: task.id,
      items: timeline[:items],
      meta: timeline[:meta]
    )
  end

  def active?
    feature_enabled?('crm_tasks') && (user_has_permission('crm_task_view') || user_has_permission('crm_task_manage'))
  end
end
