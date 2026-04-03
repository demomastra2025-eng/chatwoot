class Captain::Tools::Copilot::ChangeTaskStatusService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'change_task_status'
  end

  description 'Change the status of the CRM task linked to the current conversation'
  param :status_id, type: :number, desc: 'Target task status ID', required: false
  param :status_name, type: :string, desc: 'Target task status name', required: false
  param :status_code, type: :string, desc: 'Target task status code', required: false

  def execute(status_id: nil, status_name: nil, status_code: nil)
    task = task_operations.change_current_task_status(
      status_id: status_id,
      status_name: status_name,
      status_code: status_code
    )
    formatted_record(task)
  rescue StandardError => e
    e.message
  end

  def active?
    current_task.present? && feature_enabled?('crm_tasks') && user_has_permission('crm_task_manage')
  end

  private

  def task_operations
    Captain::Tools::Operations::TaskOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end
end
