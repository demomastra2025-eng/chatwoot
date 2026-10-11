# frozen_string_literal: true

class Captain::Runtime::TaskQueue
  STATUSES = %w[awaiting active waiting completed failed cancelled].freeze
  TERMINAL = %w[completed failed cancelled].freeze
  MAX_TASKS = 30

  def self.in_flight?(tasks)
    Array(tasks).any? { |task| TERMINAL.exclude?(task['status']) }
  end

  def initialize(context)
    @context = context
  end

  def tasks
    @context[:agent_tasks] ||= []
  end

  def active
    tasks.find { |task| task['status'] == 'active' }
  end

  def create(items)
    raise ArgumentError, 'A task queue already exists; update its remaining tasks' if tasks.any? { |task| !TERMINAL.include?(task['status']) }
    raise ArgumentError, 'Use a queue only for multiple independent requests' unless items.is_a?(Array) && items.size.between?(2, MAX_TASKS)

    proposed = items.map do |raw|
      item = raw.to_h.stringify_keys
      actor_id = Integer(item.fetch('assistant_id'))
      raise ArgumentError, 'Agent is unavailable for this conversation' unless graph.any? { |actor| actor[:id] == actor_id }
      title = item['title'].to_s.strip
      raise ArgumentError, 'Task title is required and must be short' unless title.length.between?(1, 500)

      { 'id' => SecureRandom.uuid, 'title' => title, 'assistant_id' => actor_id, 'status' => 'awaiting', 'result' => nil }
    end
    previous_tasks = tasks.deep_dup
    @context[:agent_tasks] = proposed
    activate_for_current_agent
    persist(new_queue_request_scope: request_scope)
    tasks
  rescue StandardError
    @context[:agent_tasks] = previous_tasks if previous_tasks
    raise
  end

  def update(id:, status:, result: nil)
    task = tasks.find { |item| item['id'] == id }
    raise ArgumentError, 'Task not found' unless task
    raise ArgumentError, 'Unknown task status' unless STATUSES.include?(status)
    raise ArgumentError, 'Finished tasks cannot be executed again' if TERMINAL.include?(task['status'])
    unless task['assistant_id'] == actor_id || status == 'cancelled'
      raise ArgumentError, 'Only the assigned agent can update this task'
    end
    raise ArgumentError, 'Complete the current task before activating another' if status == 'active' && active && active != task

    previous_tasks = tasks.deep_dup
    task['status'] = status
    task['result'] = result.to_s.first(1500).presence if result
    activate_for_current_agent if TERMINAL.include?(status) || status == 'waiting'
    persist
    tasks
  rescue StandardError
    @context[:agent_tasks] = previous_tasks if previous_tasks
    raise
  end

  def activate_for_current_agent
    return if active

    candidate = tasks.find { |task| task['assistant_id'] == actor_id && task['status'] == 'awaiting' }
    candidate['status'] = 'active' if candidate
  end

  def on_handoff
    previous_tasks = tasks.deep_dup
    active['status'] = 'awaiting' if active && active['assistant_id'] != actor_id
    activate_for_current_agent
    persist
  rescue StandardError
    @context[:agent_tasks] = previous_tasks if previous_tasks
    raise
  end

  def persist(new_queue_request_scope: nil)
    revision = @context[:agent_session]&.update_routing(actor_id: actor_id, tasks: tasks, new_queue_request_scope: new_queue_request_scope)
    @context[:state][:agent_routing_revision] = revision
    fence = @context.dig(:state, :captain_response_fence)
    return if fence.blank?

    fence[:entry_assistant_id] = @context.dig(:state, :entry_assistant_id)
    fence[:routing_revision] = revision
  end

  def operation_scope
    if @context[:active_part_id].present?
      return "part:#{@context[:active_part_id]}:v#{@context[:active_part_version]}"
    end
    return "task:#{active['id']}" if active

    request_scope
  end

  def request_scope
    fence = @context.dig(:state, :captain_response_fence).to_h.with_indifferent_access
    anchor = fence[:last_message_id].presence || @context[:agent_request_id]
    "request:#{anchor}"
  end

  private

  def actor_id
    @context.dig(:state, :assistant_id)
  end

  def graph
    @context[:agent_graph] || []
  end
end
