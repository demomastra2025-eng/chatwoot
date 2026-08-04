# frozen_string_literal: true

class Captain::Runtime::ToolLoopGuard
  REQUEST_COUNTS_KEY = :captain_v2_tool_request_counts
  TERMINAL_STOP_KEY = :captain_v2_terminal_tool_stop
  MAX_REQUESTS_PER_TOOL = 6
  MAX_REQUESTS_PER_RUN = 16

  def initialize(context_wrapper, tool_name)
    @context_wrapper = context_wrapper
    @tool_name = tool_name.to_s
  end

  def register_request(signature:)
    @context_wrapper.tool_loop_guard_mutex.synchronize do
      counts = request_counts
      increment_counts!(counts, signature)
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
    context[REQUEST_COUNTS_KEY] = counts
  end

  def increment_counts!(counts, signature)
    counts[:total] += 1
    counts[:by_tool][@tool_name] = counts[:by_tool].fetch(@tool_name, 0) + 1
    counts[:by_signature][signature] = counts[:by_signature].fetch(signature, 0) + 1
  end

  def request_limit_exceeded?(counts)
    counts[:total] > MAX_REQUESTS_PER_RUN || counts[:by_tool][@tool_name] > MAX_REQUESTS_PER_TOOL
  end

  def request_limit_result(counts)
    Captain::ToolResult.failure(
      error: 'Tool request limit reached. Stop calling tools and answer using the available results.',
      retryable: false,
      audit: {
        failure_stage: 'tool_request',
        failure_reason: 'tool_request_limit',
        total_requests: counts[:total],
        tool_requests: counts[:by_tool][@tool_name],
        tool_name: @tool_name
      }
    )
  end
end
