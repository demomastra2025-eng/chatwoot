# frozen_string_literal: true

class Captain::Runtime::TaskQueueTool < Captain::Runtime::Tool
  TASK_ERRORS = {
    'Task not found' => ['task_not_found', 'Use an existing task_id from own_task_ids for your unfinished task; do not invent an ID or use an assistant ID.'],
    'Only the assigned agent can update this task' => [
      'task_not_owned', 'Update your own unfinished task only. Leave another agent\'s waiting or finished task unchanged; ' \
                        'do not acknowledge it by updating its status. Hand off only if that agent has awaiting work.'
    ],
    'Finished tasks cannot be executed again' => ['task_finished', 'Leave completed, failed and cancelled tasks unchanged; do not repeat their actions.'],
    'Unknown task status' => ['invalid_task_status', 'Use active, awaiting, waiting, completed, failed or cancelled for an existing unfinished task.'],
    'Unknown task queue action' => ['invalid_task_action', 'Use create for a new multi-request plan or update with task_id and status.']
  }.freeze

  description 'Track multiple independent customer requests across agents, not every message or tool call. Creating a queue does not hand off execution. ' \
              'The response identifies current_agent_id, own_tasks and own_task_ids; tasks is the shared plan. Update your own unfinished tasks only. ' \
              'Do not update another agent\'s waiting or finished task to acknowledge it. Preserve completed results; hand off to an agent with awaiting work. ' \
              'An explicit customer cancellation may cancel another agent\'s unfinished task.'
  param :action, type: 'string', desc: 'create once for multiple independent requests; update requires task_id and status', required: true
  param :tasks, type: 'array',
        desc: 'For create only: objects with title and assistant_id, one per independent request; use the agent directory IDs', required: false
  param :task_id, type: 'string',
        desc: 'Required for update. Copy the exact id of your unfinished task from own_tasks/own_task_ids, not its title or assistant_id. ' \
              'These IDs identify ownership; the task status still determines whether an update is allowed.', required: false
  param :status, type: 'string',
        desc: 'active, awaiting, waiting, completed, failed, or cancelled. Update your own task. Resume a waiting task with active only when its missing ' \
              'information is available, before performing the action. Keep the same task_id. Completed tasks cannot be repeated.', required: false
  param :result, type: 'string',
        desc: 'Brief verified result or needed clarification; never private knowledge excerpts. A partial draft awaiting customer information ' \
              'must remain waiting. Mark completed only when the whole customer request is fulfilled, before replying or handing off.', required: false

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
    context = tool_context.run_context.context
    if action == 'update' && task_id.blank?
      return task_failure(context, code: 'task_id_required', error: 'Update requires task_id and status. Copy the exact id from own_task_ids for your unfinished task.')
    end

    queue = Captain::Runtime::TaskQueue.new(context)
    payload = case action
              when 'create' then queue.create(tasks)
              when 'update' then queue.update(id: task_id, status: status, result: result)
              else raise ArgumentError, 'Unknown task queue action'
              end
    own_tasks = owned_tasks(context, payload)
    { tasks: payload, current_agent_id: context.dig(:state, :assistant_id), own_tasks: own_tasks, own_task_ids: own_tasks.pluck('id') }.to_json
  rescue ArgumentError, KeyError, TypeError => e
    code, message = TASK_ERRORS.fetch(e.message, ['invalid_task_request', 'Invalid task queue arguments. Use create with task objects or update with task_id and status.'])
    task_failure(context, code: code, error: message)
  end

  private

  def owned_tasks(context, tasks)
    actor_id = context.dig(:state, :assistant_id)
    Array(tasks).select { |task| task['assistant_id'] == actor_id }
  end

  def task_failure(context, code:, error:)
    Captain::ToolResult.failure(
      error: error, retryable: false,
      data: { code: code, current_agent_id: context.dig(:state, :assistant_id), own_task_ids: owned_tasks(context, context[:agent_tasks]).pluck('id') },
      audit: { failure_reason: code, failure_stage: 'tool_arguments' }
    )
  end
end
