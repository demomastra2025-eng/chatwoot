class Captain::Tools::Copilot::CreateTaskService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_task'
  end

  description 'Create a CRM task from the current conversation context'
  param :title, type: :string, desc: 'Task title', required: true
  param :description, type: :string, desc: 'Task description', required: false
  param :priority, type: :string, desc: 'Task priority: low, medium, high, or urgent', required: false
  param :start_at, type: :string, desc: 'Task start datetime', required: false
  param :due_at, type: :string, desc: 'Task due datetime', required: false
  param :deal_id, type: :integer, desc: 'Optional positive account CRM deal ID to link. Omit when unknown.', required: false
  param :originating_conversation_id,
        type: :integer,
        desc: 'Optional positive account conversation display ID or internal ID to link. Omit when unknown.',
        required: false
  param :status_id, type: :integer, desc: 'Optional positive account CRM task status ID. Omit when unknown.', required: false
  param :assignee_id, type: :integer, desc: 'Optional positive account user ID to assign. Omit when unknown.', required: false
  param :team_id, type: :integer, desc: 'Optional positive account team ID to assign. Omit when unknown.', required: false
  param :custom_attributes,
        type: :string,
        desc: 'JSON object string for CRM custom attributes. Use the matching list_*_custom_fields tool first; ' \
              'only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  def execute(title:, description: nil, priority: nil, start_at: nil, due_at: nil, deal_id: nil, originating_conversation_id: nil,
              status_id: nil, assignee_id: nil, team_id: nil, custom_attributes: nil)
    task = task_operations.create_task(
      title: title,
      description: description,
      priority: priority,
      start_at: start_at,
      due_at: due_at,
      deal_id: deal_id,
      originating_conversation_id: originating_conversation_id,
      status_id: status_id,
      assignee_id: assignee_id,
      team_id: team_id,
      custom_attributes: custom_attributes
    )
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
