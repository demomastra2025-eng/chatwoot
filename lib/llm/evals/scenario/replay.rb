# frozen_string_literal: true

class Llm::Evals::Scenario::Replay
  TOOL_EVENT_MAP = {
    'llm.tool.execute' => 'tool_started',
    'llm.tool.started' => 'tool_started',
    'llm.tool.complete' => 'tool_completed',
    'llm.tool.finished' => 'tool_completed',
    'llm.tool.failed' => 'tool_failed',
    'llm.tool.error' => 'tool_failed'
  }.freeze

  def initialize(**attributes)
    @id = attributes.fetch(:id)
    @description = attributes[:description]
    @tags = attributes[:tags]
    @expected = attributes.fetch(:expected).to_h.deep_symbolize_keys
    @events = Array(attributes[:events])
    @messages = Array(attributes[:messages])
    @captain_trace = attributes[:captain_trace]
    @state = Llm::Evals::Scenario::State.new
  end

  def call
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    replay_messages!
    replay_events!
    replay_captain_trace!

    failures = Llm::Evals::Scenario::ExpectationEvaluator.new(state: @state, expected: @expected).call
    @state.succeed!('replay expectations passed') if failures.empty?
    @state.fail!(failures.join('; ')) if failures.present?

    Llm::Evals::Scenario::Result.new(
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

  def replay_messages!
    @messages.each { |message| replay_message!(message.to_h.deep_symbolize_keys) }
  end

  def replay_events!
    @events.each { |event| replay_event!(event_attributes(event)) }
  end

  def replay_captain_trace!
    trace = @captain_trace.respond_to?(:to_h) ? @captain_trace.to_h.deep_symbolize_keys : {}
    Array(trace[:tool_steps]).each { |step| replay_trace_step!(step.to_h.deep_symbolize_keys) }
    replay_message!(role: 'assistant', content: trace[:response]) if trace[:response].present?
    @state.add_event(action: 'reasoning', reasoning: trace[:reasoning]) if trace[:reasoning].present?
  end

  def replay_message!(message)
    role = (message[:role] || message[:message_role]).to_s
    return @state.add_user(message) if role == 'user'
    return @state.add_assistant(message) if role == 'assistant'

    @state.add_event(message)
  end

  def replay_event!(attributes)
    payload = attributes[:payload].respond_to?(:to_h) ? attributes[:payload].to_h.deep_symbolize_keys : {}
    event_name = event_name(attributes, payload)
    action = tool_action(event_name, attributes, payload)

    if action
      @state.add_tool_event(action, tool_payload(attributes, payload))
    elsif message_event?(attributes, payload)
      replay_message!(message_payload(attributes, payload))
    else
      @state.add_event(attributes.merge(payload: payload.presence).compact)
    end
  end

  def replay_trace_step!(step)
    action = trace_tool_action(step[:status] || step[:event])
    return unless action

    @state.add_tool_event(
      action,
      {
        tool_name: step[:tool_name],
        input: step[:input],
        result: step[:output],
        error: step[:error],
        status: step[:status],
        trace_step_id: step[:id],
        duration_ms: step[:duration_ms]
      }.compact
    )
  end

  def event_attributes(event)
    return event.attributes.deep_symbolize_keys if event.respond_to?(:attributes)
    return event.to_h.deep_symbolize_keys if event.respond_to?(:to_h)

    {}
  end

  def event_name(attributes, payload)
    attributes[:event_name] || attributes[:name] || attributes[:action] || payload[:event_name] || payload[:canonical_event_name]
  end

  def tool_action(event_name, attributes, payload)
    explicit_action = attributes[:action].presence || payload[:action].presence
    return explicit_action.to_s if %w[tool_started tool_completed tool_failed].include?(explicit_action.to_s)

    mapped_action = TOOL_EVENT_MAP[event_name.to_s]
    return 'tool_failed' if mapped_action == 'tool_completed' && tool_failed?(attributes, payload)

    mapped_action
  end

  def tool_failed?(attributes, payload)
    truthy?(attributes[:error] || payload[:error] || attributes[:tool_failure] || payload[:tool_failure])
  end

  def tool_payload(attributes, payload)
    {
      tool_name: first_value([:tool_name, :name], attributes, payload),
      input: first_value([:input, :arguments], payload),
      result: first_value([:result, :output, :message], payload),
      error: first_value([:error], attributes, payload),
      status: first_value([:status], attributes, payload),
      openrouter_generation_id: first_value([:openrouter_generation_id], attributes, payload)
    }.compact
  end

  def message_event?(attributes, payload)
    %w[user assistant].include?((attributes[:role] || payload[:role]).to_s) ||
      message_content(attributes, payload).present?
  end

  def message_payload(attributes, payload)
    {
      role: attributes[:role] || payload[:role] || inferred_message_role(attributes),
      content: message_content(attributes, payload),
      reasoning: attributes[:reasoning] || payload[:reasoning],
      openrouter_generation_id: attributes[:openrouter_generation_id] || payload[:openrouter_generation_id]
    }.compact
  end

  def inferred_message_role(attributes)
    attributes[:event_name].to_s.include?('chat.complete') || attributes[:event_name].to_s.include?('run.complete') ? 'assistant' : nil
  end

  def message_content(attributes, payload)
    attributes[:content] || attributes[:text] || attributes[:response] ||
      payload[:content] || payload[:text] || payload[:response] || payload[:output]
  end

  def trace_tool_action(status)
    case status.to_s
    when 'start', 'progress'
      'tool_started'
    when 'finish', 'complete'
      'tool_completed'
    when 'failed', 'error'
      'tool_failed'
    end
  end

  def truthy?(value)
    value == true || value.to_s == 'true'
  end

  def first_value(keys, *sources)
    keys.each do |key|
      sources.each do |source|
        value = source[key]
        return value if value.present?
      end
    end

    nil
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
