class Captain::Tools::Copilot::AddTaskCommentService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'add_task_comment'
  end

  description 'Add a comment to the CRM task linked to the current conversation'
  param :body, type: :string, desc: 'Comment body', required: true

  def execute(body:)
    comment = task_operations.add_current_task_comment(body: body)
    "Added task comment ##{comment.id}"
  rescue StandardError => e
    tool_failure(e)
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
