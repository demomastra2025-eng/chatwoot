module Captain::Assistant::RunnerCallbacksHelper
  private

  def add_callbacks_to_runner(runner)
    runner = add_agent_thinking_callback(runner) if @callbacks[:on_agent_thinking]
    runner = add_tool_start_callback(runner) if @callbacks[:on_tool_start]
    runner = add_tool_progress_callback(runner) if @callbacks[:on_tool_progress]
    runner = add_tool_complete_callback(runner) if @callbacks[:on_tool_complete]
    runner = add_llm_call_complete_callback(runner) if @callbacks[:on_llm_call_complete]
    runner = add_llm_step_callback(runner) if @callbacks[:on_llm_step]
    runner
  end

  def register_trace_input_callback(runner)
    runner.on_agent_thinking do |_agent_name, _input, context_wrapper|
      tracing = context_wrapper&.context&.dig(:__otel_tracing)
      next unless tracing

      trace_input = context_wrapper.context[:captain_v2_trace_current_input]
      tracing[:pending_llm_input] = trace_input if trace_input.present?
    end
  end

  def add_agent_thinking_callback(runner)
    runner.on_agent_thinking do |*args|
      @callbacks[:on_agent_thinking].call(*args)
    rescue StandardError => e
      Rails.logger.warn "[Captain] Callback error for agent_thinking: #{e.message}"
    end
  end

  def add_tool_start_callback(runner)
    runner.on_tool_start do |*args|
      @callbacks[:on_tool_start].call(*args)
    rescue StandardError => e
      Rails.logger.warn "[Captain] Callback error for tool_start: #{e.message}"
    end
  end

  def add_tool_progress_callback(runner)
    runner.on_tool_progress do |*args|
      @callbacks[:on_tool_progress].call(*args)
    rescue StandardError => e
      Rails.logger.warn "[Captain] Callback error for tool_progress: #{e.message}"
    end
  end

  def add_tool_complete_callback(runner)
    runner.on_tool_complete do |*args|
      @callbacks[:on_tool_complete].call(*args)
    rescue StandardError => e
      Rails.logger.warn "[Captain] Callback error for tool_complete: #{e.message}"
    end
  end

  def add_llm_step_callback(runner)
    runner.on_llm_step do |*args|
      @callbacks[:on_llm_step].call(*args)
    rescue StandardError => e
      Rails.logger.warn "[Captain] Callback error for llm_step: #{e.message}"
    end
  end

  def add_llm_call_complete_callback(runner)
    runner.on_llm_call_complete do |*args|
      @callbacks[:on_llm_call_complete].call(*args)
    rescue StandardError => e
      Rails.logger.warn "[Captain] Callback error for llm_call_complete: #{e.message}"
    end
  end
end
