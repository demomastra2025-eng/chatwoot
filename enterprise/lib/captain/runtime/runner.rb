# frozen_string_literal: true

# Runs ONE agent on a patient turn: the agent the router chose (see Captain::Runtime::DecisionRouter), with its own tools, until it
# answers, a tool hands the conversation to staff, a technical failure stops the run, or the turn limit is reached. The agent
# never changes within a run: there are no transfers between agents. A council turn runs through #run_council: the participants
# the router chose answer their parts (Captain::Runtime::Council) and one reply goes out.
class Captain::Runtime::Runner
  DEFAULT_MAX_TURNS = 10

  class MaxTurnsExceeded < StandardError; end
  class ToolLoopStopped < StandardError; end
  class AgentNotFoundError < StandardError; end
  # A technical failure of a tool ended the run (see ToolFailure). The customer gets no text: the result is an error, which the
  # runner of the conversation turns into the system handoff to staff.
  class TechnicalFailure < StandardError; end

  def self.with_agents(*agents)
    Captain::Runtime::AgentRunner.new(agents)
  end

  def self.reply_suggestion?(context)
    return false unless context.is_a?(Hash)

    (context.dig(:state, :source) || context.dig(:state, 'source')).to_s == 'reply_suggestion'
  end

  # An error ends the run as a result with an error, never as a text for the customer: the caller hands the conversation to staff.
  # A run of a live conversation that runs out of turns, or that is stopped by the loop guard, is a technical failure of the run:
  # it ends the same way as the failure of a tool, with the conversation handed to staff and no text about it.
  def run(starting_agent, input, **options)
    session = nil
    session = build_session(starting_agent, input, options)
    process_session(session)
  rescue MaxTurnsExceeded => e
    return technical_run_result(session, 'max_turns') if conversation_run?(session)

    finalize_run(session&.dig(:chat), session&.dig(:context_wrapper), session&.dig(:current_agent),
                 output: "Conversation ended: #{e.message}", error: e)
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError => e
    finalize_run(session&.dig(:chat), session&.dig(:context_wrapper), session&.dig(:current_agent), output: nil, error: e)
  end

  # A council turn. parts: the registry parts of the accepted council (exactly the participants the router chose). The acting agent
  # is the agent the turn runs as (the current agent, else the first participant); it writes nothing itself. No part has a text of
  # its own: nothing is sent (the staff handoff and note the council recorded still follow). A council whose every part failed
  # technically ends as a failed turn (a reply suggestion instead names the failed parts to the manager, see Council#assemble).
  def run_council(acting_agent, input, parts:, reassigner: nil, **options)
    wrapper = Captain::Runtime::RunContext.new(deep_copy_context(options.fetch(:context, {})), callbacks: options.fetch(:callbacks, {}))
    wrapper.callback_manager.emit_run_start(acting_agent.name, input, wrapper)
    context = wrapper.context
    answer = Captain::Runtime::Council.new(
      context: context, graph: context[:agent_graph_object], account: options[:account], llm_context: options[:llm_context],
      model: council_editor_model(acting_agent), callbacks: wrapper.callbacks, reassigner: reassigner
    ).run(parts)
    finalize_council(wrapper, acting_agent, answer)
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError => e
    finalize_run(nil, wrapper, acting_agent, output: nil, error: e)
  end

  private

  # A run of a conversation (not a council part): an exhausted or looping run is a technical failure, handed to staff.
  def conversation_run?(session)
    context = session&.dig(:context_wrapper)&.context
    context && context[:agent_session] && !context[:part_run]
  end

  def council_editor_model(acting_agent)
    acting_agent.model
  rescue StandardError
    nil
  end

  def finalize_council(wrapper, acting_agent, answer)
    context = wrapper.context
    if answer.blank? && context[:technical_failure].present?
      failure = context[:technical_failure].to_h.with_indifferent_access
      error = TechnicalFailure.new("Technical failure #{[failure[:tool], failure[:reason]].compact.join(' ')}".squish)
      return finalize_run(nil, wrapper, acting_agent, output: nil, error: error)
    end

    output = answer.blank? ? { response: '', response_mode: 'suppress', reasoning: '' } : { response: answer, reasoning: '' }
    # The language the owners of the parts wrote in goes to the logs with the reply; delivery does not read it.
    output[:patient_language] = context[:council_patient_language] if context[:council_patient_language].present?
    context[:current_agent] = acting_agent.name
    finalize_run(nil, wrapper, acting_agent, output: output)
  end

  def build_session(starting_agent, input, options)
    {
      current_agent: starting_agent,
      input: input,
      registry: options.fetch(:registry, {}),
      max_turns: options.fetch(:max_turns, DEFAULT_MAX_TURNS),
      llm_context: options[:llm_context],
      account: options[:account],
      context_wrapper: Captain::Runtime::RunContext.new(deep_copy_context(options.fetch(:context, {})), callbacks: options.fetch(:callbacks, {})),
      runtime_headers: Captain::Runtime::HashNormalizer.normalize(options[:headers], label: 'headers'),
      runtime_params: Captain::Runtime::HashNormalizer.normalize(options[:params], label: 'params'),
      finalization_only: ActiveModel::Type::Boolean.new.cast(options[:finalization_only]),
      continue_from_history: ActiveModel::Type::Boolean.new.cast(options[:continue_from_history]),
      current_turn: 0
    }.tap do |session|
      initialize_session!(session)
    end
  end

  def initialize_session!(session)
    callback_manager(session).emit_run_start(session[:current_agent].name, session[:input], session[:context_wrapper])
    rebuild_chat!(session)
    session[:input_already_in_history] = session[:continue_from_history] ||
                                         Captain::Runtime::InputComparer.last_message_matches?(session[:chat], session[:input])
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
    Captain::ReplySuggestion::RunControl.checkpoint!(:turn)
    session[:current_turn] += 1
    return unless session[:current_turn] > session[:max_turns]

    raise MaxTurnsExceeded, "Exceeded maximum turns: #{session[:max_turns]}"
  end

  def execute_turn(session)
    emit_agent_thinking(session)
    options = chat_request_options(session)

    response = if first_turn?(session) && !session[:input_already_in_history]
                 Llm::Runtime.ask(session[:chat], session[:input], **options)
               else
                 Llm::Runtime.complete(session[:chat], **options)
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

  def chat_request_options(session)
    context = session[:context_wrapper].context
    state = context[:state] || {}
    conversation = state[:conversation] || {}
    observability = {
      assistant_id: state[:assistant_id],
      current_agent: session[:current_agent].name,
      account_id: session[:account]&.id || state[:account_id],
      conversation_record_id: conversation[:id],
      conversation_display_id: conversation[:display_id],
      channel_type: state[:channel_type],
      source: state[:source],
      session_id: context[:session_id]
    }.compact

    { model: session[:current_agent].model, observability: observability }.tap do |options|
      options[:account] = session[:account] if session[:account].present?
    end
  end

  def emit_agent_thinking(session)
    current_input = first_turn?(session) ? session[:input] : '(continuing conversation)'
    callback_manager(session).emit_agent_thinking(session[:current_agent].name, current_input, session[:context_wrapper])
  end

  def first_turn?(session)
    session[:current_turn] == 1
  end

  def resolve_response(session, response)
    return technical_failure_result(session) if technical_failure_stop?(session, response)
    return terminal_tool_stop_result(session) if terminal_tool_stop?(session, response)
    return finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: response.content) if halt_response?(response)
    return if response.tool_call?

    finalize_run(
      session[:chat],
      session[:context_wrapper],
      session[:current_agent],
      output: response.content
    )
  end

  def terminal_tool_stop?(session, response)
    halt_response?(response) && terminal_tool_stop_state(session).present?
  end

  # A tool failure that ended the run: no text for the customer, the conversation goes to staff (see ToolFailure).
  def technical_failure_stop?(session, response)
    halt_response?(response) && session[:context_wrapper].context[:technical_failure].present?
  end

  def technical_failure_result(session)
    failure = session[:context_wrapper].context[:technical_failure].to_h.with_indifferent_access
    error = TechnicalFailure.new("Technical failure #{[failure[:tool], failure[:reason]].compact.join(' ')}".squish)
    finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: nil, error: error)
  end

  def technical_run_result(session, reason)
    context = session[:context_wrapper].context
    context[:technical_failure] ||= { 'kind' => Captain::Runtime::ToolFailure::TECHNICAL, 'reason' => reason }
    technical_failure_result(session)
  end

  def terminal_tool_stop_result(session)
    return technical_run_result(session, 'tool_loop') if conversation_run?(session)

    terminal_state = terminal_tool_stop_state(session).to_h.with_indifferent_access
    message = terminal_state.dig(:result, :error).presence || 'Captain stopped a repeated tool-call loop'
    error = ToolLoopStopped.new(message)
    finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: nil, error: error)
  end

  def terminal_tool_stop_state(session)
    context = session[:context_wrapper].context
    key = Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY
    context[key] || context[key.to_s]
  end

  def halt_response?(response)
    response.is_a?(RubyLLM::Tool::Halt)
  end

  def rebuild_chat!(session)
    session[:chat] = Captain::Runtime::ChatFactory.build(
      agent: session[:current_agent],
      context_wrapper: session[:context_wrapper],
      llm_context: session[:llm_context],
      account: session[:account],
      runtime_headers: session[:runtime_headers],
      runtime_params: session[:runtime_params],
      finalization_only: session[:finalization_only]
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
  end

  def track_usage(response, context_wrapper)
    context_wrapper&.usage&.add(response)
  end
end
