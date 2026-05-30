class Captain::Tools::Copilot::CompleteTaskService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'complete_task'
  end

  description 'Mark an account CRM task as complete by task ID'
  param :task_id, type: :integer, desc: 'Positive account-scoped CRM task ID to complete', required: true

  def execute(task_id:)
    task = task_operations.complete_task(task_id: task_id)

    formatted_payload(::Crm::ToolPayloadBuilder.task_payload(action: 'complete_task', task: task))
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_tasks') && user_has_permission('crm_task_manage')
  end

  private

  def task_operations
    Captain::Tools::Operations::TaskOperations.new(
      assistant: assistant,
      actor: @user
    )
  end
end
