# frozen_string_literal: true

class Captain::Evals::Scenario::CaptainAgentAdapter < Llm::Evals::Scenario::AgentAdapter
  def initialize(assistant:, conversation: nil, runner_service_factory: nil)
    super(role: :agent, name: 'CaptainAgent')
    @assistant = assistant
    @conversation = conversation
    @runner_service_factory = runner_service_factory || default_runner_service_factory
  end

  def call(input)
    response = runner_service(input).generate_response(message_history: message_history(input))
    normalized_response = normalize_response(response)

    Llm::Evals::Scenario::AgentAdapter::Output.new(
      messages: [assistant_message(normalized_response)],
      events: trace_events(normalized_response),
      verdict: verdict(normalized_response),
      reasoning: normalized_response[:reasoning]
    )
  end

  private

  def runner_service(input)
    @runner_service_factory.call(
      assistant: @assistant,
      conversation: @conversation,
      callbacks: scenario_callbacks(input)
    )
  end

  def default_runner_service_factory
    lambda do |assistant:, conversation:, callbacks:|
      Captain::Assistant::AgentRunnerService.new(
        assistant: assistant,
        conversation: conversation,
        callbacks: callbacks,
        source: 'eval_scenario'
      )
    end
  end

  def scenario_callbacks(input)
    input.fixtures.to_h.fetch(:callbacks, {})
  end

  def message_history(input)
    input.messages.map do |message|
      {
        role: message[:role],
        content: message[:content] || message[:text] || message[:response],
        agent_name: message[:agent_name],
        tool_calls: message[:tool_calls],
        tool_call_id: message[:tool_call_id]
      }.compact
    end
  end

  def normalize_response(response)
    response.respond_to?(:to_h) ? response.to_h.deep_symbolize_keys : { response: response.to_s }
  end

  def assistant_message(response)
    {
      role: 'assistant',
      content: response[:response].presence || response[:content].presence || '',
      reasoning: response[:reasoning],
      structured_reasoning: response[:structured_reasoning],
      agent_name: response[:agent_name],
      ui_actions: response[:ui_actions],
      captain_trace: response[:captain_trace],
      openrouter_generation_id: response[:openrouter_generation_id]
    }.compact
  end

  def trace_events(response)
    tool_events(response) + runtime_events(response)
  end

  def tool_events(response)
    trace = response[:captain_trace].respond_to?(:to_h) ? response[:captain_trace].to_h.deep_symbolize_keys : {}
    Array(trace[:tool_steps]).filter_map { |step| tool_event(step) }
  end

  def tool_event(raw_step)
    step = raw_step.to_h.deep_symbolize_keys
    action = tool_action(step[:status] || step[:event])
    return unless action

    {
      action: action,
      tool_name: step[:tool_name],
      input: step[:input],
      result: step[:output],
      error: step[:error],
      status: step[:status],
      trace_step_id: step[:id],
      duration_ms: step[:duration_ms]
    }.compact
  end

  def runtime_events(response)
    event = {
      action: 'run_complete',
      event_name: 'llm.run.complete',
      agent_name: response[:agent_name],
      error: response[:error_class].present?,
      error_class: response[:error_class],
      error_message: response[:error_message],
      openrouter_generation_id: response[:openrouter_generation_id]
    }.compact

    [event]
  end

  def tool_action(status)
    case status.to_s
    when 'start', 'progress'
      'tool_started'
    when 'finish', 'complete'
      'tool_completed'
    when 'failed', 'error'
      'tool_failed'
    end
  end

  def verdict(response)
    response[:error_class].present? ? 'failure' : nil
  end
end
