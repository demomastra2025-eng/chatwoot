# frozen_string_literal: true

require 'digest'

# Durable conversation-local state. Playground state lives exclusively in its
# existing temporary session. No shared-contact key is used for task execution.
class Captain::Conversation::AgentSession
  ATTRIBUTE = 'captain_agent_session'
  MAX_OPERATIONS = 100
  # The last routing decisions the next turn reads (the bounce guard and the state of the router).
  TRAIL_LIMIT = 3
  BLOCKED = { 'status' => 'blocked', 'reason' => 'mutation_retry_blocked' }.freeze

  def initialize(entry:, conversation: nil, playground: nil, fence: {}, ephemeral: false)
    @entry, @playground = entry, playground
    @conversation = ::Conversation.where(account_id: entry.account_id).find(conversation.id) if conversation && !playground
    @fence = fence.to_h.symbolize_keys
    @ephemeral_mode = ephemeral
  end

  def read
    raw = if @playground
            @playground.data[ATTRIBUTE]
          elsif @ephemeral_mode
            @ephemeral ||= (@conversation ? @conversation.reload.additional_attributes.to_h[ATTRIBUTE] : nil)
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
    if @conversation && !@ephemeral_mode
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
    return change { |data| yield(data) } if !@conversation || @ephemeral_mode

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

  # The router chose who answers this turn (see Captain::Runtime::RoutingState). actor_id: the agent that holds the conversation
  # now (nil keeps the current one: a staff request, or a council when an agent already holds it); trail: the decision, for
  # the next turn. A change of the holder raises the routing revision, which the response fence of a run carries.
  def update_routing(actor_id:, trail: nil)
    change do |data|
      expected = @task_revision || data['task_revision'].to_i
      if data['task_revision'].to_i != expected
        raise Captain::Conversation::ControlGenerationStaleError, 'Agent routing changed during this run'
      end
      if actor_id.present? && data['current_assistant_id'] != actor_id
        data['routing_revision'] = data['routing_revision'].to_i + 1
        data['current_assistant_id'] = actor_id
        data['task_revision'] = expected + 1
      end
      append_trail(data, trail)
      @task_revision = data['task_revision'].to_i
      data['routing_revision'].to_i
    end
  end

  # peer_part: the actor is the owner of a council part, which does not hold the conversation. Its part is still checked
  # against its own executor, only the current agent of the conversation is not.
  def reserve_operation(scope:, tool:, arguments:, actor_id:, peer_part: false)
    target = Captain::Runtime::OperationTarget.of(tool, arguments)
    key = operation_key(scope, tool, target)
    digest = Digest::SHA256.hexdigest(JSON.generate(canonical(arguments)))
    change do |data|
      if @task_revision && data['task_revision'].to_i != @task_revision
        raise Captain::Conversation::ControlGenerationStaleError, 'Agent task queue changed before this action'
      end
      if scope.to_s.start_with?('part:')
        part_id, version = scope.to_s.match(/\Apart:([^:]+):v(\d+)\z/)&.captures
        part = Array(data['parts']).find { |item| item['id'] == part_id }
        unless part && part['version'].to_i == version.to_i && part['executor_agent_id'] == actor_id &&
               (peer_part || data['current_assistant_id'] == actor_id) && part['cancelled'] != true
          raise Captain::Conversation::ControlGenerationStaleError, 'Request part is no longer executable'
        end
      end
      operations = data['operations'] ||= {}
      prior = operations[key]
      next [:existing, prior.deep_dup] if prior && !corrected_call?(prior, digest)

      # A new version of a part (an answer, a correction) must not repeat an action that an earlier version did, or may have
      # done: that call may already have reached the provider.
      earlier = earlier_version_receipt(operations, scope, tool, digest, target)
      next earlier if earlier

      # The receipts of every version of every part that is still in the registry stay: they are that memory.
      retained_scopes = Array(data['parts']).flat_map { |item| (1..item['version'].to_i).map { |number| "part:#{item['id']}:v#{number}" } } + [scope]
      operations.delete_if { |_id, operation| operation['status'] == 'finished' && !retained_scopes.include?(operation['scope']) }
      raise ArgumentError, 'Too many actions in this conversation session' if operations.size >= MAX_OPERATIONS

      operations[key] = { 'arguments_digest' => digest, 'status' => 'executing', 'actor_id' => actor_id, 'scope' => scope }
      [:reserved, key]
    end
  end

  # outcome: success, not_executed (the call was rejected, nothing changed) or unknown (it may or may not have happened); read
  # from the result when it is not given. done: the line of the action for the list "Done in this conversation" (see
  # Captain::DoneActions); it is kept only for an action that happened.
  def finish_operation(key, result, outcome: nil, done: nil)
    record do |data|
      operation = data.fetch('operations').fetch(key)
      operation['status'] = 'finished'
      operation['outcome'] = (outcome.presence || Captain::Runtime::ToolFailure.outcome(result)).to_s
      operation['result'] = JSON.parse(JSON.generate(result.as_json))
      remember_done(data, done) if done.present? && operation['outcome'] == Captain::Runtime::ToolFailure::SUCCESS
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

  def record_done(done)
    return if done.blank?

    record { |data| remember_done(data, done) }
  end

  # Context copies within the same run must share the same durable session and
  # temporary Playground instance, not independently overwrite its state.
  def deep_dup = self

  private

  def append_trail(data, trail)
    return if trail.blank?

    data['routing_trail'] = (Array(data['routing_trail']) + [trail.deep_stringify_keys]).last(TRAIL_LIMIT)
  end

  def compatible?(data)
    data['entry_assistant_id'] == @entry.id
  end

  def remember_done(data, done)
    data['done'] = Captain::DoneActions.remember(data['done'], done.deep_stringify_keys)
  end

  # One receipt per scope, tool and target (see Captain::Runtime::OperationTarget): the person a booking is for, the appointment a
  # change is for. A call without a target keeps the key of the scope and the tool alone.
  def operation_key(scope, tool, target = nil)
    Digest::SHA256.hexdigest(JSON.generate(target ? [scope, tool, target] : [scope, tool]))
  end

  # What the receipts of the earlier versions of the same part say about the same tool, newest first:
  #   executing                      -> blocked (the call may already have reached the provider)
  #   finished, success              -> the same call is answered with the stored result, another one is blocked
  #   finished, not_executed         -> nothing happened, the next version may try (this is skipped)
  #   finished, unknown or no outcome (a receipt of an older release) -> blocked
  # nil when no earlier version decides.
  def earlier_version_receipt(operations, scope, tool, digest, target = nil)
    part_id, version = scope.to_s.match(/\Apart:([^:]+):v(\d+)\z/)&.captures
    return unless part_id

    (1...version.to_i).to_a.reverse_each do |earlier|
      receipt = operations[operation_key("part:#{part_id}:v#{earlier}", tool, target)]
      next unless receipt

      decision = receipt_decision(receipt, digest)
      return decision if decision
    end
    nil
  end

  # The receipt of this scope says that the call changed nothing (a business answer such as a taken slot, or a rejection for its
  # arguments) and the new call is a different one: it is the correction the agent makes in the same run, so it takes the
  # place of that receipt. The same rule lets a later version of a part repeat what did not happen (earlier_version_receipt).
  # A receipt of a call that is executing, succeeded or has an unknown outcome stays: that call may have reached the provider.
  def corrected_call?(receipt, digest)
    receipt['status'] == 'finished' && receipt['outcome'] == Captain::Runtime::ToolFailure::NOT_EXECUTED &&
      receipt['arguments_digest'] != digest
  end

  def receipt_decision(receipt, digest)
    return [:existing, BLOCKED.deep_dup] unless receipt['status'] == 'finished'

    case receipt['outcome']
    when 'not_executed' then nil
    when 'success' then [:existing, receipt['arguments_digest'] == digest ? receipt.deep_dup : BLOCKED.deep_dup]
    else [:existing, BLOCKED.deep_dup]
    end
  end

  def refresh_epoch(data)
    return data if data['epoch'] == epoch

    data['epoch'] = epoch
    data
  end

  # A new conversation has no agent yet: the router chooses among all agents of the clinic on the first message (there is no main
  # agent). entry_assistant_id is the technical anchor of the channel (the assistant the inbox is bound to), not an agent role.
  def fresh
    { 'entry_assistant_id' => @entry.id, 'current_assistant_id' => nil, 'routing_revision' => 0, 'task_revision' => 0,
      'epoch' => epoch, 'parts' => [], 'operations' => {}, 'routing_trail' => [] }
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
