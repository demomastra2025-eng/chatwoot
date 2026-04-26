# frozen_string_literal: true

class Captain::Runtime::Runner
  DEFAULT_MAX_TURNS = 10

  class MaxTurnsExceeded < StandardError; end
  class AgentNotFoundError < StandardError; end
  class SelfHandoffError < StandardError; end

  def self.with_agents(*agents)
    Captain::Runtime::AgentRunner.new(agents)
  end

  def run(starting_agent, input, **options)
    session = nil
    session = build_session(starting_agent, input, options)
    process_session(session)
  rescue MaxTurnsExceeded => e
    finalize_run(session&.dig(:chat), session&.dig(:context_wrapper), session&.dig(:current_agent),
                 output: "Conversation ended: #{e.message}", error: e)
  rescue StandardError => e
    finalize_run(session&.dig(:chat), session&.dig(:context_wrapper), session&.dig(:current_agent), output: nil, error: e)
  end

  private

  def build_session(starting_agent, input, options)
    {
      current_agent: starting_agent,
      input: input,
      registry: options.fetch(:registry, {}),
      max_turns: options.fetch(:max_turns, DEFAULT_MAX_TURNS),
      llm_context: options[:llm_context],
      context_wrapper: Captain::Runtime::RunContext.new(deep_copy_context(options.fetch(:context, {})), callbacks: options.fetch(:callbacks, {})),
      runtime_headers: Captain::Runtime::HashNormalizer.normalize(options[:headers], label: 'headers'),
      runtime_params: Captain::Runtime::HashNormalizer.normalize(options[:params], label: 'params'),
      current_turn: 0
    }.tap do |session|
      initialize_session!(session)
    end
  end

  def initialize_session!(session)
    callback_manager(session).emit_run_start(session[:current_agent].name, session[:input], session[:context_wrapper])
    rebuild_chat!(session)
    session[:input_already_in_history] = Captain::Runtime::InputComparer.last_message_matches?(session[:chat], session[:input])
  end

  def process_session(session)
    loop do
      advance_turn!(session)

      response = execute_turn(session)
      result = resolve_response(session, response)
      return result if result
    end
  end

  def advance_turn!(session)
    session[:current_turn] += 1
    return unless session[:current_turn] > session[:max_turns]

    raise MaxTurnsExceeded, "Exceeded maximum turns: #{session[:max_turns]}"
  end

  def execute_turn(session)
    emit_agent_thinking(session)

    response = if first_turn?(session) && !session[:input_already_in_history]
                 Llm::ChatClient.ask(session[:chat], session[:input])
               else
                 Llm::StructuredOutputPolicy.execute(chat: session[:chat]) { session[:chat].complete }
               end

    track_usage(response, session[:context_wrapper])
    callback_manager(session).emit_llm_call_complete(
      session[:current_agent].name,
      session[:current_agent].model,
      response,
      session[:context_wrapper]
    )
    response
  end

  def emit_agent_thinking(session)
    current_input = first_turn?(session) ? session[:input] : '(continuing conversation)'
    callback_manager(session).emit_agent_thinking(session[:current_agent].name, current_input, session[:context_wrapper])
  end

  def first_turn?(session)
    session[:current_turn] == 1
  end

  def resolve_response(session, response)
    return handle_handoff(session) if handoff_requested?(session, response)
    return finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: response.content) if halt_response?(response)
    return if response.tool_call?

    finalize_run(
      session[:chat],
      session[:context_wrapper],
      session[:current_agent],
      output: response.content
    )
  end

  def handoff_requested?(session, response)
    halt_response?(response) && session[:context_wrapper].context[:pending_handoff]
  end

  def halt_response?(response)
    response.is_a?(RubyLLM::Tool::Halt)
  end

  def handle_handoff(session)
    next_agent = handoff_target(session)
    return self_handoff_result(session, next_agent) if self_handoff?(session, next_agent)
    return missing_agent_result(session, next_agent) unless session[:registry][next_agent.name]

    persist_handoff_state(session, next_agent)
    reset_session_for_handoff!(session, next_agent)
    nil
  end

  def handoff_target(session)
    session[:context_wrapper].context.delete(:pending_handoff)[:target_agent]
  end

  def missing_agent_result(session, next_agent)
    error = AgentNotFoundError.new("Handoff failed: Agent '#{next_agent.name}' not found in registry")
    finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: nil, error: error)
  end

  def self_handoff?(session, next_agent)
    current_agent = session[:current_agent]
    next_agent.equal?(current_agent) || next_agent.name == current_agent.name
  end

  def self_handoff_result(session, next_agent)
    error = SelfHandoffError.new("Agent #{next_agent.name} attempted to hand off to itself")
    finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: nil, error: error)
  end

  def persist_handoff_state(session, next_agent)
    save_conversation_state(session[:chat], session[:context_wrapper], session[:current_agent])
    callback_manager(session).emit_agent_complete(session[:current_agent].name, nil, nil, session[:context_wrapper])
    callback_manager(session).emit_agent_handoff(
      session[:current_agent].name,
      next_agent.name,
      'handoff',
      session[:context_wrapper]
    )
  end

  def reset_session_for_handoff!(session, next_agent)
    session[:current_agent] = next_agent
    session[:context_wrapper].context[:current_agent] = next_agent.name
    session[:input] = nil
    session[:input_already_in_history] = false
    rebuild_chat!(session)
  end

  def rebuild_chat!(session)
    session[:chat] = Captain::Runtime::ChatFactory.build(
      agent: session[:current_agent],
      context_wrapper: session[:context_wrapper],
      llm_context: session[:llm_context],
      runtime_headers: session[:runtime_headers],
      runtime_params: session[:runtime_params]
    )
  end

  def callback_manager(session)
    session[:context_wrapper].callback_manager
  end

  def finalize_run(chat, context_wrapper, current_agent, output:, error: nil)
    save_conversation_state(chat, context_wrapper, current_agent) if chat

    result = Captain::Runtime::Result.new(
      output: output,
      messages: chat ? Captain::Runtime::MessageExtractor.extract_messages(chat, current_agent) : [],
      usage: context_wrapper&.usage,
      error: error,
      context: context_wrapper&.context
    )

    context_wrapper&.callback_manager&.emit_agent_complete(current_agent.name, result, error, context_wrapper)
    context_wrapper&.callback_manager&.emit_run_complete(current_agent.name, result, context_wrapper)

    result
  end

  def deep_copy_context(context)
    context.deep_dup.tap do |copied|
      copied[:conversation_history] ||= []
      copied[:turn_count] ||= 0
    end
  end

  def save_conversation_state(chat, context_wrapper, current_agent)
    context_wrapper.context[:conversation_history] = Captain::Runtime::MessageExtractor.extract_messages(chat, current_agent)
    context_wrapper.context[:current_agent] = current_agent.name
    context_wrapper.context[:turn_count] = (context_wrapper.context[:turn_count] || 0) + 1
    context_wrapper.context[:last_updated] = Time.current
    context_wrapper.context.delete(:pending_handoff)
  end

  def track_usage(response, context_wrapper)
    context_wrapper&.usage&.add(response)
  end
end
