class Captain::Tools::Copilot::CreateTaskService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_task'
  end

  description 'Create a CRM task from the current conversation context'
  param :title, type: :string, desc: 'Task title', required: true
  param :description, type: :string, desc: 'Task description', required: false
  param :activity_type, type: :string, desc: 'Task type: task, call, meeting, message, or touch', required: false
  param :outcome, type: :string, desc: 'Task outcome/result, for example held, no_show, answered, sent, or not_done', required: false
  param :outcome_note, type: :string, desc: 'Task result details: what was done or why it was not done', required: false
  param :priority, type: :string, desc: 'Task priority: low, medium, high, or urgent', required: false
  param :all_day, type: :boolean, desc: 'Use a date-only all-day deadline', required: false
  param :start_at, type: :string, desc: 'Task start datetime', required: false
  param :due_at, type: :string, desc: 'Task due datetime', required: false
  param :due_on, type: :string, desc: 'Task due date (YYYY-MM-DD) when all_day is true', required: false
  param :schedule_timezone, type: :string, desc: 'IANA timezone for task scheduling', required: false
  param :context_kind,
        type: :string,
        desc: 'Task context: sales or personal. Sales requires a deal; personal may be standalone.',
        required: false
  param :deal_id, type: :integer, desc: 'Optional positive account CRM deal ID to link. Omit when unknown.', required: false
  param :originating_conversation_id,
        type: :integer,
        desc: 'Optional positive account conversation display ID or internal ID to link. Omit when unknown.',
        required: false
  param :status_id, type: :integer, desc: 'Optional positive account CRM task status ID. Omit when unknown.', required: false
  param :assignee_id, type: :integer, desc: 'Optional positive account user ID to assign. Omit when unknown.', required: false
  param :team_id,
        type: :integer,
        desc: 'Optional positive account team ID for a standalone task. Tasks linked to a deal inherit its team.',
        required: false
  param :custom_attributes,
        type: :string,
        desc: 'JSON object string for CRM custom attributes. Use the matching list_*_custom_fields tool first; ' \
              'only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  def execute(title:, **attributes)
    task = task_operations.create_task(title: title, **attributes)
    formatted_payload(::Crm::ToolPayloadBuilder.task_payload(action: 'create_task', task: task))
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
