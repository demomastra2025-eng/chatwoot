class Captain::Tools::ChangeTaskStatusTool < Captain::Tools::BasePublicTool
  description 'Change the status of the CRM task linked to the current conversation'
  param :status_id, type: 'integer', desc: 'Positive target task status ID. Omit when unknown.', required: false
  param :status_name, type: 'string', desc: 'Target task status name', required: false
  param :status_code, type: 'string', desc: 'Target task status code', required: false

  def perform(tool_context, status_id: nil, status_name: nil, status_code: nil)
    task = operations(tool_context.state).change_current_task_status(
      status_id: status_id,
      status_name: status_name,
      status_code: status_code
    )

    JSON.pretty_generate(::Crm::ToolPayloadBuilder.task_payload(action: 'change_task_status', task: task))
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
