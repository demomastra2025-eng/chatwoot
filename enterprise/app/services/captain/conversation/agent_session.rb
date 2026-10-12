# frozen_string_literal: true

require 'digest'

# Durable conversation-local state. Playground state lives exclusively in its
# existing temporary session. No shared-contact key is used for task execution.
class Captain::Conversation::AgentSession
  ATTRIBUTE = 'captain_agent_session'
  MAX_OPERATIONS = 100

  def initialize(entry:, conversation: nil, playground: nil, fence: {})
    @entry, @playground = entry, playground
    @conversation = ::Conversation.where(account_id: entry.account_id).find(conversation.id) if conversation && !playground
    @fence = fence.to_h.symbolize_keys
  end

  def read
    raw = if @playground
            @playground.data[ATTRIBUTE]
          elsif @conversation
            @conversation.reload.additional_attributes.to_h[ATTRIBUTE]
          else
            @ephemeral
          end
    data = raw.to_h.deep_stringify_keys
    data = fresh unless compatible?(data)
    @task_revision ||= data['task_revision'].to_i
    refresh_epoch(data).deep_dup
  end

  def change
    if @conversation
      @conversation.with_lock do
        ensure_current!
        attributes = @conversation.additional_attributes.to_h.deep_dup
        data = attributes[ATTRIBUTE].to_h.deep_stringify_keys
        data = fresh unless compatible?(data)
        refresh_epoch(data)
        result = yield(data)
        attributes[ATTRIBUTE] = data
        # State bookkeeping must not trigger replies, providers or automations.
        @conversation.update_column(:additional_attributes, attributes)
        result
      end
    else
      data = read
      result = yield(data)
      if @playground
        @playground.data[ATTRIBUTE] = data
        @playground.save!
      else
        @ephemeral = data
      end
      result
    end
  end

  # Bookkeeping for a provider call that already happened. Unlike `change` it does not require
  # the run to be current: staff may have taken over or a newer message arrived meanwhile, and
  # the outcome must still be stored. It does not refresh the epoch, so nothing else is paused.
  def record
    return change { |data| yield(data) } unless @conversation

    @conversation.with_lock do
      attributes = @conversation.additional_attributes.to_h.deep_dup
      data = attributes[ATTRIBUTE].to_h.deep_stringify_keys
      next unless compatible?(data)

      result = yield(data)
      attributes[ATTRIBUTE] = data
      @conversation.update_column(:additional_attributes, attributes)
      result
    end
  end

  def update_routing(actor_id:, tasks: nil, new_queue_request_scope: nil)
    change do |data|
      expected = @task_revision || data['task_revision'].to_i
      if data['task_revision'].to_i != expected
        raise Captain::Conversation::ControlGenerationStaleError, 'Agent task queue changed during this run'
      end
      if new_queue_request_scope
        already_planned = data['queue_request_scope'] == new_queue_request_scope
        already_started = data.fetch('operations', {}).values.any? { |operation| operation['scope'] == new_queue_request_scope }
        if already_planned || already_started
          raise ArgumentError, 'Plan requests once, before taking actions. Keep the existing task IDs and recorded outcomes.'
        end
        data['queue_request_scope'] = new_queue_request_scope
      end
      changed = data['current_assistant_id'] != actor_id || (tasks && data['tasks'] != tasks)
      if data['current_assistant_id'] != actor_id
        data['routing_revision'] = data['routing_revision'].to_i + 1
      end
      data['current_assistant_id'] = actor_id
      data['tasks'] = tasks.deep_dup if tasks
      data['task_revision'] = expected + 1 if changed
      @task_revision = data['task_revision'].to_i
      data['routing_revision'].to_i
    end
  end

  def reserve_operation(scope:, tool:, arguments:, actor_id:)
    key = operation_key(scope, tool)
    digest = Digest::SHA256.hexdigest(JSON.generate(canonical(arguments)))
    change do |data|
      if @task_revision && data['task_revision'].to_i != @task_revision
        raise Captain::Conversation::ControlGenerationStaleError, 'Agent task queue changed before this action'
      end
      # Once an input has a plan, its actions must retain the planned task IDs.
      # Completing or waiting all tasks must not open a fresh unscoped receipt.
      if data['queue_request_scope'] == scope
        pending = Array(data['tasks']).any? { |task| %w[awaiting active waiting].include?(task['status']) }
        next [:existing, { 'status' => 'blocked', 'reason' => pending ? 'agent_task_not_active' : 'mutation_retry_blocked' }]
      end

      if scope.to_s.start_with?('task:')
        task = Array(data['tasks']).find { |item| "task:#{item['id']}" == scope }
        unless task && task['status'] == 'active' && task['assistant_id'] == actor_id && data['current_assistant_id'] == actor_id
          raise Captain::Conversation::ControlGenerationStaleError, 'Agent task is no longer active for this actor'
        end
      end
      if scope.to_s.start_with?('part:')
        part_id, version = scope.to_s.match(/\Apart:([^:]+):v(\d+)\z/)&.captures
        part = Array(data['parts']).find { |item| item['id'] == part_id }
        unless part && part['version'].to_i == version.to_i && part['executor_agent_id'] == actor_id &&
               data['current_assistant_id'] == actor_id && part['cancelled'] != true
          raise Captain::Conversation::ControlGenerationStaleError, 'Request part is no longer executable'
        end
      end
      operations = data['operations'] ||= {}
      prior = operations[key]
      next [:existing, prior.deep_dup] if prior
      # A new version of a part (confirmation, correction) must not repeat an action that an earlier
      # version started without ever recording its outcome: that call may already have reached the provider.
      next [:existing, { 'status' => 'blocked', 'reason' => 'mutation_retry_blocked' }] if earlier_version_unresolved?(operations, scope, tool)

      retained_scopes = Array(data['tasks']).map { |item| "task:#{item['id']}" } +
                        Array(data['parts']).map { |item| "part:#{item['id']}:v#{item['version']}" } + [scope]
      operations.delete_if { |_id, operation| operation['status'] == 'finished' && !retained_scopes.include?(operation['scope']) }
      raise ArgumentError, 'Too many actions in this conversation session' if operations.size >= MAX_OPERATIONS

      operations[key] = { 'arguments_digest' => digest, 'status' => 'executing', 'actor_id' => actor_id, 'scope' => scope }
      [:reserved, key]
    end
  end

  def finish_operation(key, result)
    record do |data|
      operation = data.fetch('operations').fetch(key)
      operation['status'] = 'finished'
      operation['result'] = JSON.parse(JSON.generate(result.as_json))
    end
  end

  def arguments_match?(operation, arguments)
    operation['arguments_digest'] == Digest::SHA256.hexdigest(JSON.generate(canonical(arguments)))
  end

  def release_unexecuted_operation(key)
    record do |data|
      operations = data.fetch('operations')
      operations.delete(key) if operations.dig(key, 'status') == 'executing'
    end
  end

  # Context copies within the same run must share the same durable session and
  # temporary Playground instance, not independently overwrite its state.
  def deep_dup = self

  private

  def compatible?(data)
    data['entry_assistant_id'] == @entry.id
  end

  def operation_key(scope, tool)
    Digest::SHA256.hexdigest(JSON.generate([scope, tool]))
  end

  def earlier_version_unresolved?(operations, scope, tool)
    part_id, version = scope.to_s.match(/\Apart:([^:]+):v(\d+)\z/)&.captures
    return false unless part_id

    (1...version.to_i).any? { |earlier| operations.dig(operation_key("part:#{part_id}:v#{earlier}", tool), 'status') == 'executing' }
  end

  def refresh_epoch(data)
    return data if data['epoch'] == epoch

    data['epoch'] = epoch
    Array(data['tasks']).each do |task|
      next unless %w[active awaiting].include?(task['status'])

      task['status'] = 'waiting'
      task['result'] = 'Paused after a change in conversation control; check the current customer request before resuming.'
    end
    data
  end

  def fresh
    { 'entry_assistant_id' => @entry.id, 'current_assistant_id' => legacy_actor_id || @entry.id, 'routing_revision' => 0, 'task_revision' => 0,
      'epoch' => epoch, 'tasks' => [], 'parts' => [], 'operations' => {} }
  end

  def legacy_actor_id
    return unless @conversation

    last_reply = @conversation.messages.outgoing.where(private: false).reorder(created_at: :desc, id: :desc).first
    return unless last_reply&.sender_type == 'Captain::Assistant' && last_reply.sender_id == @entry.id
    return if @conversation.status_transitions.where('created_at > ?', last_reply.created_at).exists?

    key = last_reply.additional_attributes.to_h['agent_name']
    return unless key.to_s.start_with?('scenario_')

    Captain::AgentGraph.new(@entry, inbox: @conversation.inbox).resolve(key)&.id
  rescue Captain::AgentGraph::EntryDisabledError
    nil
  end

  def epoch
    return @playground.id if @playground
    return 'ephemeral' unless @conversation

    [@conversation.current_captain_control_generation, @conversation.status_transitions.maximum(:id)].join(':')
  end

  def ensure_current!
    Captain::Conversation::RunFenceService.new(
      assistant: @entry,
      state: { account_id: @entry.account_id, assistant_id: @entry.id,
               conversation: { id: @conversation.id }, captain_response_fence: @fence }
    ).ensure_current!
  end

  def canonical(value)
    case value
    when Hash then value.stringify_keys.sort.to_h.transform_values { |item| canonical(item) }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end
end
