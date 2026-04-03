class Captain::Tools::CreateTaskTool < Captain::Tools::BasePublicTool
  description 'Create a CRM task from the current conversation context'
  param :title, type: 'string', desc: 'Task title', required: true
  param :description, type: 'string', desc: 'Task description', required: false
  param :priority, type: 'string', desc: 'Task priority: low, medium, high, urgent', required: false
  param :start_at, type: 'string', desc: 'Task start datetime', required: false
  param :due_at, type: 'string', desc: 'Task due datetime', required: false
  param :custom_attributes_json, type: 'string', desc: 'Optional custom attributes as JSON object', required: false

  def perform(tool_context, title:, description: nil, priority: nil, start_at: nil, due_at: nil, custom_attributes_json: nil)
    task = operations(tool_context.state).create_task(
      title: title,
      description: description,
      priority: priority,
      start_at: start_at,
      due_at: due_at,
      custom_attributes: custom_attributes_json
    )

    "Created task #{task.title} (ID: #{task.id})"
  rescue StandardError => e
    e.message
  end

  private

  def operations(state)
    Captain::Tools::Operations::TaskOperations.new(
      assistant: assistant,
      conversation: current_conversation(state)
    )
  end
end
