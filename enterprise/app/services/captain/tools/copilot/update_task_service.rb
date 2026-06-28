class Captain::Tools::Copilot::UpdateTaskService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_task'
  end

  description 'Update the CRM task linked to the current conversation'
  param :title, type: :string, desc: 'Updated task title', required: false
  param :description, type: :string, desc: 'Updated task description', required: false
  param :activity_type, type: :string, desc: 'Updated task type: task, call, meeting, message, or touch', required: false
  param :outcome, type: :string, desc: 'Updated task outcome/result, for example held, no_show, answered, sent, or not_done', required: false
  param :outcome_note, type: :string, desc: 'Updated task result details: what was done or why it was not done', required: false
  param :priority, type: :string, desc: 'Updated task priority: low, medium, high, or urgent', required: false
  param :start_at, type: :string, desc: 'Updated start datetime', required: false
  param :due_at, type: :string, desc: 'Updated due datetime', required: false
  param :custom_attributes,
        type: :string,
        desc: 'JSON object string for CRM custom attributes. Use the matching list_*_custom_fields tool first; ' \
              'only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  def execute(
    title: nil,
    description: nil,
    activity_type: nil,
    outcome: nil,
    outcome_note: nil,
    priority: nil,
    start_at: nil,
    due_at: nil,
    custom_attributes: nil
  )
    task = task_operations.update_current_task(
      title: title,
      description: description,
      activity_type: activity_type,
      outcome: outcome,
      outcome_note: outcome_note,
      priority: priority,
      start_at: start_at,
      due_at: due_at,
      custom_attributes: custom_attributes
    )
    formatted_payload(::Crm::ToolPayloadBuilder.task_payload(action: 'update_task', task: task))
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
