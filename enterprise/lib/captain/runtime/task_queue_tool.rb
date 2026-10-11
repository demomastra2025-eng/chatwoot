# frozen_string_literal: true

class Captain::Runtime::TaskQueueTool < Captain::Runtime::Tool
  description 'Track multiple independent customer requests across agents. Do not create a task for every message or tool call. '
  param :action, type: 'string', desc: 'create or update', required: true
  param :tasks, type: 'array', desc: 'For create: objects with title and assistant_id, one per independent customer request', required: false
  param :task_id, type: 'string', desc: 'Existing queue task ID for update', required: false
  param :status, type: 'string',
        desc: 'active, waiting, completed, failed, or cancelled. Update your own task. Resume a waiting task with active only when its missing ' \
              'information is available, before performing the action. Keep the same task_id. Completed tasks cannot be repeated.', required: false
  param :result, type: 'string', desc: 'Brief verified result or needed clarification; never private knowledge excerpts', required: false

  def name = 'manage_agent_tasks'

  def params_schema
    super.deep_stringify_keys.tap do |schema|
      schema['properties']['tasks']['items'] = {
        'type' => 'object', 'additionalProperties' => false,
        'properties' => { 'title' => { 'type' => 'string' }, 'assistant_id' => { 'type' => 'integer', 'minimum' => 1 } },
        'required' => %w[title assistant_id]
      }
    end
  end

  def perform(tool_context, action:, tasks: nil, task_id: nil, status: nil, result: nil)
    queue = Captain::Runtime::TaskQueue.new(tool_context.run_context.context)
    payload = case action
              when 'create' then queue.create(tasks)
              when 'update' then queue.update(id: task_id, status: status, result: result)
              else raise ArgumentError, 'Unknown task queue action'
              end
    { tasks: payload }.to_json
  rescue ArgumentError, KeyError, TypeError => e
    Captain::ToolResult.failure(error: e.message, retryable: false)
  end
end
