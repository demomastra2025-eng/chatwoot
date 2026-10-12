# frozen_string_literal: true

class Captain::Runtime::TaskQueueTool < Captain::Runtime::Tool
  TASK_ERRORS = {
    'Task not found' => ['task_not_found', 'Use the id of your unfinished task from own_task_ids; do not invent an id or use an assistant id.'],
    'Only the assigned agent can update this task' => [
      'task_not_owned', 'Update your own unfinished task only; leave another agent\'s waiting or finished task unchanged. ' \
                        'Transfer only if that agent has awaiting work.'
    ],
    'Finished tasks cannot be executed again' => [
      'task_finished', 'Leave completed, failed and cancelled tasks unchanged; do not repeat their actions.'
    ],
    'Unknown task status' => ['invalid_task_status', 'Use active, awaiting, waiting, completed, failed or cancelled for an unfinished task.'],
    'Unknown task queue action' => ['invalid_task_action', 'Use create for a new multi-request plan or update with task_id and status.']
  }.freeze

  description 'Track several independent patient requests across agents, not every message. The result lists tasks, own_tasks and ' \
              'own_task_ids. Update only your own unfinished tasks and keep completed results; creating a queue transfers nothing. ' \
              'Only an explicit cancellation by the patient may cancel another agent\'s unfinished task.'
  param :action, type: 'string', desc: 'create (once, for several independent requests) or update (needs task_id and status).', required: true
  param :tasks, type: 'array', desc: 'For create: one object per request, with title and the assistant_id of its agent.', required: false
  param :task_id, type: 'string', desc: 'For update: the id of your unfinished task, copied from own_task_ids.', required: false
  param :status, type: 'string',
                 desc: 'active, awaiting, waiting, completed, failed or cancelled. completed only when the whole request is done; ' \
                       'waiting while a patient answer is missing; set it back to active before acting once the answer is known.',
                 required: false
  param :result, type: 'string', desc: 'The verified result or the question that is needed, in a few words; no private excerpts.', required: false

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
      error = 'Update requires task_id and status. Copy the id from own_task_ids for your unfinished task.'
      return task_failure(context, code: 'task_id_required', error: error)
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
