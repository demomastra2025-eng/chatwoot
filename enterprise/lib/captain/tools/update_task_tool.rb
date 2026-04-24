class Captain::Tools::UpdateTaskTool < Captain::Tools::BasePublicTool
  description 'Update the CRM task linked to the current conversation'
  param :title, type: 'string', desc: 'Updated task title', required: false
  param :description, type: 'string', desc: 'Updated task description', required: false
  param :priority, type: 'string', desc: 'Updated task priority: low, medium, high, or urgent', required: false
  param :start_at, type: 'string', desc: 'Updated start datetime', required: false
  param :due_at, type: 'string', desc: 'Updated due datetime', required: false
  param :custom_attributes, type: 'object', desc: 'Optional custom attributes object', required: false

  def perform(tool_context, title: nil, description: nil, priority: nil, start_at: nil, due_at: nil, custom_attributes: nil)
    task = operations(tool_context.state).update_current_task(
      title: title,
      description: description,
      priority: priority,
      start_at: start_at,
      due_at: due_at,
      custom_attributes: custom_attributes
    )

    JSON.pretty_generate(
      action: 'update_task',
      task: ::Crm::PayloadBuilder.task(task)
    )
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
