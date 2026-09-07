class Captain::Tools::Copilot::UpdateTaskService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_task'
  end

  description 'Update a CRM task by task_id or the task linked to the current conversation'
  param :task_id,
        type: :integer,
        desc: 'Optional positive account CRM task ID. Use an ID returned by get_task/search_tasks; omit for the current conversation task.',
        required: false
  param :title, type: :string, desc: 'Updated task title', required: false
  param :description, type: :string, desc: 'Updated task description', required: false
  param :activity_type, type: :string, desc: 'Updated task type: task, call, meeting, message, or touch', required: false
  param :outcome, type: :string, desc: 'Updated task outcome/result, for example held, no_show, answered, sent, or not_done', required: false
  param :outcome_note, type: :string, desc: 'Updated task result details: what was done or why it was not done', required: false
  param :priority, type: :string, desc: 'Updated task priority: low, medium, high, or urgent', required: false
  param :all_day, type: :boolean, desc: 'Use a date-only all-day deadline', required: false
  param :start_at, type: :string, desc: 'Updated start datetime', required: false
  param :due_at, type: :string, desc: 'Updated due datetime', required: false
  param :due_on, type: :string, desc: 'Updated due date (YYYY-MM-DD) when all_day is true', required: false
  param :schedule_timezone, type: :string, desc: 'Updated IANA schedule timezone', required: false
  param :custom_attributes,
        type: :string,
        desc: 'JSON object string for CRM custom attributes. Use the matching list_*_custom_fields tool first; ' \
              'only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  def execute(
    task_id: Captain::Tools::Operations::TaskOperations::TASK_ID_UNSET,
    title: nil,
    description: nil,
    activity_type: nil,
    outcome: nil,
    outcome_note: nil,
    priority: nil,
    all_day: nil,
    start_at: nil,
    due_at: nil,
    due_on: nil,
    schedule_timezone: nil,
    custom_attributes: nil
  )
    task = task_operations.update_current_task(
      task_id: task_id,
      title: title,
      description: description,
      activity_type: activity_type,
      outcome: outcome,
      outcome_note: outcome_note,
      priority: priority,
      all_day: all_day,
      start_at: start_at,
      due_at: due_at,
      due_on: due_on,
      schedule_timezone: schedule_timezone,
      custom_attributes: custom_attributes
    )
    formatted_payload(::Crm::ToolPayloadBuilder.task_payload(action: 'update_task', task: task))
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
      conversation: current_conversation,
      actor: @user
    )
  end
end
