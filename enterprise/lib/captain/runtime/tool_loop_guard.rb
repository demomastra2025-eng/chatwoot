# frozen_string_literal: true

class Captain::Runtime::ToolLoopGuard
  REQUEST_COUNTS_KEY = :captain_v2_tool_request_counts
  TERMINAL_STOP_KEY = :captain_v2_terminal_tool_stop
  MAX_REQUESTS_PER_TOOL = 6
  MAX_REQUESTS_PER_RUN = 16
  MAX_COORDINATION_REQUESTS = 64
  MAX_REQUESTS_BY_TOOL = {
    'search_scheduling_services' => 4
  }.freeze

  def initialize(context_wrapper, tool_name, coordination: false, task_scope: nil)
    @context_wrapper = context_wrapper
    @tool_name = tool_name.to_s
    @coordination = coordination
    @task_scope = task_scope if task_scope.to_s.start_with?('task:')
  end

  def register_request(signature:)
    @context_wrapper.tool_loop_guard_mutex.synchronize do
      counts = request_counts
      increment_counts!(counts, signature)
      publish_scheduling_budget_shadow(counts)
      request_limit_result(counts) if request_limit_exceeded?(counts)
    end
  end

  def terminal_result
    @context_wrapper.tool_loop_guard_mutex.synchronize do
      terminal_state = context[TERMINAL_STOP_KEY] || context[TERMINAL_STOP_KEY.to_s]
      next unless terminal_state.respond_to?(:[])

      terminal_state[:result] || terminal_state['result']
    end
  end

  def stop!(result)
    @context_wrapper.tool_loop_guard_mutex.synchronize do
      context[TERMINAL_STOP_KEY] ||= {
        tool_name: @tool_name,
        result: result.deep_dup,
        stopped_at: Time.current.iso8601
      }
    end
  end

  private

  def context
    @context_wrapper.context
  end

  def request_counts
    existing = context[REQUEST_COUNTS_KEY] || context[REQUEST_COUNTS_KEY.to_s]
    counts = existing.respond_to?(:deep_symbolize_keys) ? existing.deep_symbolize_keys : {}
    counts[:total] = counts[:total].to_i
    counts[:by_tool] = counts[:by_tool].to_h.stringify_keys
    counts[:by_signature] = counts[:by_signature].to_h.stringify_keys
    counts[:by_task] = counts[:by_task].to_h.stringify_keys
    context[REQUEST_COUNTS_KEY] = counts
  end

  def increment_counts!(counts, signature)
    if @coordination
      counts[:coordination_total] = counts[:coordination_total].to_i + 1
    else
      counts[:total] += 1
      counts[:by_task][@task_scope] = counts[:by_task].fetch(@task_scope, 0) + 1 if @task_scope
    end
    counts[:by_tool][request_count_key] = counts[:by_tool].fetch(request_count_key, 0) + 1
    counts[:by_signature][signature] = counts[:by_signature].fetch(signature, 0) + 1
  end

  def request_limit_exceeded?(counts)
    return counts[:coordination_total].to_i > MAX_COORDINATION_REQUESTS if @coordination

    total_limit = @task_scope ? MAX_REQUESTS_PER_RUN * Captain::Runtime::TaskQueue::MAX_TASKS : MAX_REQUESTS_PER_RUN
    task_limit_exceeded = @task_scope && counts[:by_task].fetch(@task_scope, 0) > MAX_REQUESTS_PER_RUN
    counts[:total] > total_limit || task_limit_exceeded || counts[:by_tool][request_count_key] > max_requests_for_tool
  end

  def request_limit_result(counts)
    return tool_budget_exceeded_result(counts) if scheduling_tool_budget_exceeded?(counts)

    Captain::ToolResult.failure(
      error: 'Tool request limit reached. Stop calling tools and answer using the available results.',
      retryable: false,
      audit: {
        failure_stage: 'tool_request',
        failure_reason: 'tool_request_limit',
        total_requests: counts[:total],
        tool_requests: counts[:by_tool][request_count_key],
        tool_name: @tool_name
      }
    )
  end

  def tool_budget_exceeded_result(counts)
    allowed = max_requests_for_tool
    attempted = counts[:by_tool][request_count_key]
    publish_scheduling_budget_blocked(allowed: allowed, attempted: attempted)
    Captain::ToolResult.failure(
      error: 'Scheduling service search budget exceeded. Use the available service results.',
      data: { code: 'tool_budget_exceeded', allowed: allowed, attempted: attempted },
      retryable: false,
      audit: {
        failure_stage: 'tool_request',
        failure_reason: 'tool_budget_exceeded',
        allowed: allowed,
        attempted: attempted,
        tool_name: canonical_tool_name
      }
    )
  end

  def max_requests_for_tool
    return MAX_REQUESTS_PER_TOOL unless scheduling_grounding_guard_enabled?

    MAX_REQUESTS_BY_TOOL.fetch(canonical_tool_name, MAX_REQUESTS_PER_TOOL)
  end

  def scheduling_tool_budget_exceeded?(counts)
    scheduling_grounding_guard_enabled? &&
      MAX_REQUESTS_BY_TOOL.key?(canonical_tool_name) &&
      counts[:by_tool][request_count_key] > max_requests_for_tool
  end

  def request_count_key
    name = MAX_REQUESTS_BY_TOOL.key?(canonical_tool_name) ? canonical_tool_name : @tool_name
    @task_scope && !@coordination ? "#{@task_scope}:#{name}" : name
  end

  def canonical_tool_name
    MAX_REQUESTS_BY_TOOL.keys.find do |name|
      @tool_name == name || @tool_name.end_with?("__#{name}") || @tool_name.end_with?(":#{name}")
    end || @tool_name
  end

  def publish_scheduling_budget_blocked(allowed:, attempted:)
    state = context[:state].to_h.with_indifferent_access
    Llm::EventBus.publish(
      'captain.scheduling_tool_budget_blocked',
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      account_id: state[:account_id],
      conversation_id: state.dig(:conversation, :id),
      tool_name: canonical_tool_name,
      allowed: allowed,
      attempted: attempted,
      enforced: scheduling_grounding_guard_enabled?
    )
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ToolLoopGuard] Failed to publish scheduling budget block: #{e.class}: #{e.message}")
  end

  def publish_scheduling_budget_shadow(counts)
    return unless canonical_tool_name == 'search_scheduling_services'
    return if scheduling_grounding_guard_enabled?

    allowed = MAX_REQUESTS_BY_TOOL.fetch(canonical_tool_name)
    attempted = counts[:by_tool][request_count_key]
    publish_scheduling_budget_blocked(allowed: allowed, attempted: attempted) if attempted == allowed + 1
  end

  def scheduling_grounding_guard_enabled?
    state = context[:state].to_h.with_indifferent_access
    ActiveModel::Type::Boolean.new.cast(state[:captain_scheduling_grounding_guard_enabled])
  end
end
