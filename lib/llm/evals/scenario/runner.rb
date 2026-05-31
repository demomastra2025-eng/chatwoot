# frozen_string_literal: true

class Llm::Evals::Scenario::Runner
  STEP_HANDLERS = {
    'user' => :execute_user_step, 'assistant' => :execute_assistant_step, 'agent' => :execute_agent_step,
    'tool_started' => :execute_tool_step, 'tool_completed' => :execute_tool_step, 'tool_failed' => :execute_tool_step,
    'message' => :execute_message_step, 'judge' => :execute_assertion_step, 'assert' => :execute_assertion_step,
    'proceed' => :execute_proceed_step, 'succeed' => :execute_succeed_step, 'fail' => :execute_fail_step
  }.freeze

  def initialize(**attributes)
    assign_case_attributes(attributes)
    assign_runtime_attributes(attributes)
  end

  def call
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    if @trace_collector
      @trace_collector.capture { execute_script }
    else
      execute_script
    end

    failures = final_failures
    ::Llm::Evals::Scenario::Result.new(
      id: @id,
      description: @description,
      tags: @tags,
      expected: @expected,
      state: @state,
      failures: failures,
      duration_ms: elapsed_ms(started_at)
    )
  end

  private

  def assign_case_attributes(attributes)
    @id = attributes.fetch(:id)
    @description = attributes[:description]
    @tags = attributes[:tags]
    @expected = attributes.fetch(:expected).to_h.deep_symbolize_keys
    @fixtures = attributes.fetch(:fixtures, {}).to_h.deep_symbolize_keys
    @account = attributes[:account]
    @max_turns = normalize_max_turns(attributes[:max_turns])
    @script = ::Llm::Evals::Scenario::Script.new(::Llm::Evals::Scenario::ScriptBuilder.new(attributes: attributes).call)
  end

  def assign_runtime_attributes(attributes)
    @agents_by_role = Array(attributes[:agents]).index_by { |agent| agent.role.to_s }
    @adapter_positions = Hash.new(-1)
    @state = ::Llm::Evals::Scenario::State.new
    @trace_collector = attributes[:trace_collector]
  end

  def execute_script
    @script.steps.each do |step|
      break if @state.terminal?

      execute_step(step)
      enforce_max_turns!
    end
  end

  def execute_step(step)
    handler = STEP_HANDLERS[step.type] || raise(ArgumentError, "unsupported scenario step: #{step.type}")
    send(handler, step)
  end

  def execute_user_step(step) = @state.add_user(step.payload)
  def execute_assistant_step(step) = @state.add_assistant(step.payload)
  def execute_tool_step(step) = @state.add_tool_event(step.type, step.payload)
  def execute_message_step(step) = @state.add_event(step.payload)
  def execute_succeed_step(step) = @state.succeed!(step_reason(step.payload))
  def execute_fail_step(step) = @state.fail!(step_reason(step.payload))

  def execute_agent_step(step)
    normalized_payload = normalize_step_payload(step.payload)
    if normalized_payload.present? && !normalized_payload[:call]
      @state.add_assistant(normalized_payload)
      return
    end

    call_adapter!('agent')
  end

  def execute_assertion_step(step)
    normalized_payload = normalize_step_payload(step.payload)
    return call_adapter!('judge') if normalized_payload[:call]

    expectation = normalized_payload[:expected].presence || @expected
    failures = ::Llm::Evals::Scenario::ExpectationEvaluator.new(state: @state, expected: expectation).call
    return if failures.empty?

    @state.fail!(failures.join('; '))
  end

  def execute_proceed_step(step)
    turns = normalize_step_payload(step.payload)[:turns].to_i
    turns = 1 unless turns.positive?

    turns.times do
      call_adapter('user')
      call_adapter('agent')
      call_adapter('judge')
      break if @state.terminal?

      enforce_max_turns!
    end
  end

  def call_adapter(role)
    adapter = @agents_by_role[role.to_s]
    return unless adapter

    apply_agent_output(role, adapter.call(adapter_input(role)))
    @adapter_positions[role.to_s] = @state.events.size - 1
  end

  def call_adapter!(role)
    adapter = @agents_by_role[role.to_s]
    raise ArgumentError, "missing scenario #{role} adapter" unless adapter

    apply_agent_output(role, adapter.call(adapter_input(role)))
    @adapter_positions[role.to_s] = @state.events.size - 1
  end

  def adapter_input(role)
    previous_index = @adapter_positions[role.to_s]

    ::Llm::Evals::Scenario::AgentAdapter::Input.new(
      thread_id: @state.thread_id,
      messages: @state.messages,
      new_messages: @state.new_messages_after(previous_index),
      state: @state,
      fixtures: @fixtures,
      account: @account,
      trace_events: @trace_collector&.events || []
    )
  end

  def apply_agent_output(role, output)
    normalized_output = normalize_agent_output(output)
    Array(normalized_output[:messages]).each do |message|
      normalized_message = normalize_step_payload(message)
      message_role = normalized_message.delete(:role).presence || agent_message_role(role)
      @state.add_message(message_role, normalized_message)
    end

    Array(normalized_output[:events]).each { |event| @state.add_event(event) }

    case normalized_output[:verdict].to_s
    when 'success', 'pass'
      @state.succeed!(normalized_output[:reasoning])
    when 'failure', 'fail'
      @state.fail!(normalized_output[:reasoning])
    end
  end

  def normalize_agent_output(output)
    case output
    when ::Llm::Evals::Scenario::AgentAdapter::Output
      output.to_h
    when Hash
      output.deep_symbolize_keys
    else
      { messages: [{ role: nil, content: output.to_s }] }
    end
  end

  def agent_message_role(role)
    role.to_s == 'agent' ? 'assistant' : role.to_s
  end

  def final_failures
    return [@state.terminal_reason || 'scenario failed'] if @state.terminal_status == 'fail'

    failures = ::Llm::Evals::Scenario::ExpectationEvaluator.new(state: @state, expected: @expected).call
    @state.succeed!('scenario expectations passed') if failures.empty? && !@state.terminal?
    failures
  end

  def enforce_max_turns!
    return if @max_turns.blank? || @state.turn_count <= @max_turns

    @state.fail!("max turns exceeded: #{@state.turn_count} > #{@max_turns}")
  end

  def normalize_step_payload(payload)
    return {} if payload.nil?

    payload.respond_to?(:to_h) ? payload.to_h.deep_symbolize_keys : { content: payload.to_s }
  end

  def normalize_max_turns(max_turns)
    normalized_max_turns = max_turns.to_i
    normalized_max_turns.positive? ? normalized_max_turns : nil
  end

  def step_reason(payload)
    normalized_payload = normalize_step_payload(payload)
    normalized_payload[:reason].presence || normalized_payload[:reasoning].presence || normalized_payload[:content].presence
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
