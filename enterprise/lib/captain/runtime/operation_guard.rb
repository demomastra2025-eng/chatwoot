# frozen_string_literal: true

# Claims an action before calling a provider. If a worker dies after the provider
# accepted it, a later run must reconcile the outcome instead of sending again.
class Captain::Runtime::OperationGuard
  def initialize(context, tool, arguments, scope: nil)
    @context, @tool, @arguments = context, tool, arguments
    @session = context[:agent_session]
    @scope = scope || Captain::Runtime::TaskQueue.new(context).operation_scope
  end

  def reserve
    return unless @session && Llm::ToolRiskPolicy.mutating?(@tool)
    return if @tool.is_a?(Captain::Runtime::HandoffTool) || @tool.is_a?(Captain::Runtime::TaskQueueTool) ||
              @tool.is_a?(Captain::Runtime::PartPlanTool)
    # These tools already atomically change conversation ownership/status. They
    # must remain available after all business tasks finish or need staff help.
    return if @tool.is_a?(Captain::Tools::HandoffTool) || @tool.is_a?(Captain::Tools::ResolveConversationTool)
    return if @context[:playground_session] # Real Playground actions have their own exact approval ledger.

    # The owner of a council part is not the agent that holds the conversation: its part is checked against its own executor.
    status, entry = @session.reserve_operation(
      scope: @scope,
      tool: @tool.name.to_s, arguments: @arguments, actor_id: actor_id, peer_part: @context[:part_run] == true
    )
    if status == :reserved
      @key = entry
      return
    end
    if entry['reason'] == 'agent_task_not_active'
      return Captain::ToolResult.failure(
        error: 'This action was not started: the request has a task plan but no active task for this action. ' \
               'Resume the appropriate existing task only when its required information is available, or hand it to its assigned agent. ' \
               'Keep existing task IDs and completed results; do not create a replacement plan.',
        retryable: false,
        audit: { failure_reason: 'agent_task_not_active', failure_stage: 'tool_execution', mutation_executed: false }
      )
    end
    return replay(entry) if entry['status'] == 'finished' && @session.arguments_match?(entry, @arguments)

    Captain::ToolResult.failure(
      error: 'This action was already started for this request. Check its recorded result before taking another action; do not repeat it.',
      retryable: false, audit: { failure_reason: 'mutation_retry_blocked', failure_stage: 'tool_execution' }
    )
  end

  def finish(result)
    return unless @key

    normalized = Captain::ToolResult.normalize(result)
    if normalized[:success] == false && normalized.dig(:audit, :mutation_executed) == false &&
       normalized.dig(:audit, :failure_stage) == 'tool_arguments'
      @session.release_unexecuted_operation(@key)
    else
      # The receipt remembers whether the action happened: a later version of the same part may repeat only what did not.
      outcome = Captain::Runtime::ToolFailure.outcome(result)
      done = done_entry(result) if outcome == Captain::Runtime::ToolFailure::SUCCESS
      @session.finish_operation(@key, normalized, outcome: outcome, done: done)
      remember_done(done)
    end
  end

  private

  # The action as one line of the "Done in this conversation" list (see Captain::DoneActions). The receipt keeps it for the next
  # messages; the run keeps it for the agent that gets the conversation by a transfer in this same run.
  def done_entry(result)
    Captain::DoneActions.entry(tool_name: @tool.name, arguments: @arguments, result: result,
                               request: Captain::Runtime::TaskQueue.new(@context).request_scope)
  end

  def remember_done(done)
    @context[:done_actions] = Captain::DoneActions.remember(@context[:done_actions], done) if done
  end

  def actor_id = @context.dig(:state, :assistant_id)

  def replay(entry)
    # A transferred actor may not inherit private tool payloads from its peer.
    # It can query the affected record using its own tools and permissions.
    if entry['actor_id'] != actor_id
      return Captain::ToolResult.failure(
        error: 'Another agent already completed this action. Read the current record with your own permitted tools; do not repeat the action.',
        retryable: false, audit: { failure_reason: 'mutation_retry_blocked', failure_stage: 'tool_execution' }
      )
    end

    entry.fetch('result').deep_symbolize_keys.tap do |result|
      result[:audit] = result.fetch(:audit, {}).merge(cached_result_reused: true)
    end
  end
end
