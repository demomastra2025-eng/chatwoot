class Captain::Tools::CreateTaskTool < Captain::Tools::BasePublicTool
  description 'Create a CRM task from the current conversation context'
  param :title, type: 'string', desc: 'Task title', required: true
  param :description, type: 'string', desc: 'Task description', required: false
  param :activity_type, type: 'string', desc: 'Task type: task, call, meeting, message, or touch', required: false
  param :outcome, type: 'string', desc: 'Task outcome/result, for example held, no_show, answered, sent, or not_done', required: false
  param :outcome_note, type: 'string', desc: 'Task result details: what was done or why it was not done', required: false
  param :priority, type: 'string', desc: 'Task priority: low, medium, high, or urgent', required: false
  param :all_day, type: 'boolean', desc: 'Use a date-only all-day deadline', required: false
  param :start_at, type: 'string', desc: 'Task start datetime', required: false
  param :due_at, type: 'string', desc: 'Task due datetime', required: false
  param :due_on, type: 'string', desc: 'Task due date (YYYY-MM-DD) when all_day is true', required: false
  param :schedule_timezone, type: 'string', desc: 'IANA timezone for task scheduling', required: false
  param :deal_id, type: 'integer', desc: 'Optional positive account CRM deal ID to link. Omit when unknown.', required: false
  param :originating_conversation_id,
        type: 'integer',
        desc: 'Optional positive account conversation display ID or internal ID to link. Omit when unknown.',
        required: false
  param :custom_attributes,
        type: 'string',
        desc: 'JSON object string for CRM custom attributes. Use the matching list_*_custom_fields tool first; ' \
              'only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  def perform(
    tool_context,
    title:,
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
    deal_id: nil,
    originating_conversation_id: nil,
    custom_attributes: nil
  )
    task = operations(tool_context.state).create_task(
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
      deal_id: deal_id,
      originating_conversation_id: originating_conversation_id,
      custom_attributes: custom_attributes
    )

    JSON.pretty_generate(::Crm::ToolPayloadBuilder.task_payload(action: 'create_task', task: task))
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def operations(state)
    Captain::Tools::Operations::TaskOperations.new(
      assistant: assistant,
      conversation: current_conversation(state)
    )
  end
end
