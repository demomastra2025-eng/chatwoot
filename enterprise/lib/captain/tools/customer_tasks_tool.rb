class Captain::Tools::CustomerTasksTool < Captain::Tools::BasePublicTool
  description 'List, create, update, or cancel customer-visible tasks for the current contact and communication thread'
  param :action, type: 'string', desc: 'Action: list, create, update, or cancel', required: true
  param :task_id, type: 'integer', desc: 'Customer task ID for update or cancel', required: false
  param :title, type: 'string', desc: 'Customer-visible task title', required: false
  param :task_type, type: 'string', desc: 'Configured task type code for create', required: false
  param :all_day, type: 'boolean', desc: 'Use a date-only deadline', required: false
  param :due_at, type: 'string', desc: 'Deadline datetime in ISO 8601', required: false
  param :due_on, type: 'string', desc: 'Deadline date (YYYY-MM-DD) for an all-day task', required: false
  param :request_reason,
        type: 'string',
        desc: 'Requested change or cancellation reason; required when changing an in-progress task',
        required: false
  param :idempotency_key,
        type: 'string',
        desc: 'Stable unique request key; required for create, update, and cancel',
        required: false

  def perform(
    tool_context,
    action:,
    task_id: nil,
    title: nil,
    task_type: nil,
    all_day: nil,
    due_at: nil,
    due_on: nil,
    request_reason: nil,
    idempotency_key: nil
  )
    result = Captain::CustomerTasks::Service.new(
      assistant: assistant,
      conversation: current_conversation(tool_context.state)
    ).call(
      action: action,
      task_id: task_id,
      title: title,
      task_type: task_type,
      all_day: all_day,
      due_at: due_at,
      due_on: due_on,
      request_reason: request_reason,
      idempotency_key: idempotency_key
    )

    JSON.pretty_generate(result)
  rescue StandardError => e
    tool_failure(e)
  end
end
