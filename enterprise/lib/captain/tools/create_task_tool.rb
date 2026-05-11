class Captain::Tools::CreateTaskTool < Captain::Tools::BasePublicTool
  description 'Create a CRM task from the current conversation context'
  param :title, type: 'string', desc: 'Task title', required: true
  param :description, type: 'string', desc: 'Task description', required: false
  param :priority, type: 'string', desc: 'Task priority: low, medium, high, or urgent', required: false
  param :start_at, type: 'string', desc: 'Task start datetime', required: false
  param :due_at, type: 'string', desc: 'Task due datetime', required: false
  param :custom_attributes,
        type: 'string',
        desc: 'JSON object string for CRM custom attributes. Use the matching list_*_custom_fields tool first; ' \
              'only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  def perform(tool_context, title:, description: nil, priority: nil, start_at: nil, due_at: nil, custom_attributes: nil)
    task = operations(tool_context.state).create_task(
      title: title,
      description: description,
      priority: priority,
      start_at: start_at,
      due_at: due_at,
      custom_attributes: custom_attributes
    )

    JSON.pretty_generate(
      action: 'create_task',
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
