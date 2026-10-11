# frozen_string_literal: true

class Captain::Runtime::Runner
  DEFAULT_MAX_TURNS = 10
  MAX_TASK_FINALIZATION_REPAIRS = 2

  class MaxTurnsExceeded < StandardError; end
  class ToolLoopStopped < StandardError; end
  class AgentNotFoundError < StandardError; end
  class SelfHandoffError < StandardError; end
  class UnresolvedTasksError < StandardError; end

  def self.with_agents(*agents)
    Captain::Runtime::AgentRunner.new(agents)
  end

  def run(starting_agent, input, **options)
    session = nil
    session = build_session(starting_agent, input, options)
    process_session(session)
  rescue MaxTurnsExceeded => e
    if part_run?(session)
      return finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: open_parts_response(session))
    end

    finalize_run(session&.dig(:chat), session&.dig(:context_wrapper), session&.dig(:current_agent),
                 output: "Conversation ended: #{e.message}", error: e)
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError => e
    finalize_run(session&.dig(:chat), session&.dig(:context_wrapper), session&.dig(:current_agent), output: nil, error: e)
  end

  private

  def part_run?(session)
    context = session&.dig(:context_wrapper)&.context
    context && context[:agent_session] && !Captain::Runtime::TaskQueue.in_flight?(context[:agent_tasks])
  end

  def open_parts_response(session)
    parts = Array(session[:context_wrapper].context[:parts]).select do |part|
      Captain::Runtime::PartRegistry::OPEN_STATES.include?(part['state'])
    end
    fragments = parts.map { |part| part['fragment'].to_s.first(160) }.reject(&:blank?)
    text = I18n.t('captain.coordination.unfinished', locale: :ru)
    text += " #{I18n.t('captain.coordination.open_parts', parts: fragments.join('; '), locale: :ru)}" if fragments.any?
    { response: text, reasoning: '' }
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
    return terminal_tool_stop_result(session) if terminal_tool_stop?(session, response)
    return continue_after_transfer_guard(session) if session[:context_wrapper].context.delete(:transfer_guard_active)
    return handle_handoff(session) if handoff_requested?(session, response)
    plan_result = handle_plan(session)
    return plan_result if plan_result
    return finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: response.content) if halt_response?(response)
    return if response.tool_call?
    return if continue_unresolved_tasks?(session, response)
    plan_state = ensure_part_plan(session, response)
    return if plan_state == :retry
    if plan_state == :unavailable
      return finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: open_parts_response(session))
    end

    finalize_run(
      session[:chat],
      session[:context_wrapper],
      session[:current_agent],
      output: response.content
    )
  end

  def handle_plan(session)
    context = session[:context_wrapper].context
    plan = context[:part_plan]
    return if plan.blank? || context[:part_plan_processed]

    context[:part_plan_processed] = true
    if plan[:parts].all? { |part| part['link_action'] == 'cancellation' }
      return finalize_run(session[:chat], session[:context_wrapper], session[:current_agent],
                          output: { response: I18n.t('captain.coordination.cancelled', locale: :ru), reasoning: '' })
    end
    if plan[:parts].all? { |part| part['link_action'] == 'confirmation' }
      answer = Captain::Runtime::ConfirmedOperations.new(context: context, graph: context[:agent_graph_object]).run(plan[:parts])
      session[:current_agent] = session[:registry]["assistant_#{context.dig(:state, :assistant_id)}"] || session[:current_agent]
      return finalize_run(session[:chat], session[:context_wrapper], session[:current_agent],
                          output: { response: answer, reasoning: '' })
    end

    case plan[:mode]
    when 'council'
      answer = Captain::Runtime::Council.new(context: context, graph: context[:agent_graph_object],
                                             account: session[:account], llm_context: session[:llm_context]).run(plan[:parts])
      finalize_run(session[:chat], session[:context_wrapper], session[:current_agent],
                   output: { response: answer, reasoning: '' })
    when 'handoff'
      target_id = plan[:parts].first['executor_agent_id']
      context[:pending_handoff] = { target_agent: "assistant_#{target_id}" }
      handle_handoff(session)
    when 'clarify'
      registry = Captain::Runtime::PartRegistry.new(context)
      plan[:parts].each do |part|
        registry.update!(part['id'], state: 'waiting_customer')
      end
      finalize_run(session[:chat], session[:context_wrapper], session[:current_agent],
                   output: { response: plan[:clarification], reasoning: '' })
    when 'answer_myself'
      if plan[:answer].present?
        Captain::Runtime::PartRegistry.new(context).update!(plan[:parts].first['id'], state: 'answered')
        finalize_run(session[:chat], session[:context_wrapper], session[:current_agent],
                     output: { response: plan[:answer], reasoning: '' })
      end
    end
  end

  def ensure_part_plan(session, response)
    context = session[:context_wrapper].context
    return true if context[:agent_graph].blank? || Captain::Runtime::TaskQueue.in_flight?(context[:agent_tasks]) ||
                   context[:part_plan_accepted]
    return true if context[:consult_mode]

    if session[:plan_repairs].to_i.zero?
      session[:plan_repairs] = 1
      discard_unpublished_draft(session[:chat], response)
      session[:chat].add_message(role: :system, content: 'Call plan_request for this message before replying.')
      return :retry
    end
    :unavailable
  end

  def continue_after_transfer_guard(session)
    session[:context_wrapper].context[:transfer_guarded] = true
    rebuild_chat!(session)
    session[:chat].add_message(role: :system, content: <<~PROMPT)
      Internal routing is unavailable for this message. Answer from verified facts already available.
      State what remains open. Do not ask a new question or transfer to staff.
    PROMPT
    nil
  end

  def continue_unresolved_tasks?(session, response)
    return false if session[:finalization_only]

    context = session[:context_wrapper].context
    tasks = context[:agent_tasks] || []
    return false unless tasks.any? { |task| %w[active awaiting].include?(task['status']) }

    discard_unpublished_draft(session[:chat], response)
    repairs = session[:task_finalization_repairs].to_i
    raise UnresolvedTasksError, 'Independent customer requests still need an outcome before replying' if repairs >= MAX_TASK_FINALIZATION_REPAIRS

    session[:task_finalization_repairs] = repairs + 1
    session[:chat].add_message(role: :system, content: <<~PROMPT)
      The draft reply has not been sent. The request queue still contains active or awaiting work.
      Record the verified outcome of your own task with manage_agent_tasks: completed, waiting for a specific customer fact, failed, or cancelled.
      A partial draft that still needs customer information remains waiting, not completed.
      Use completed tool results already in this conversation; do not repeat completed business actions.
      If another agent has awaiting work, transfer to that assigned agent using an available handoff.
      Do not change another agent's task. Once no active or awaiting work remains, give one customer reply covering the results and what is waiting.
      Current agent ID (data): #{JSON.generate(context.dig(:state, :assistant_id))}
      Current request queue (data): #{JSON.generate(tasks)}
    PROMPT
    true
  end

  def discard_unpublished_draft(chat, response)
    last = chat.messages.last
    return unless last&.role == :assistant && !last.tool_call? && last.content == response.content

    chat.messages.pop
  end

  def terminal_tool_stop?(session, response)
    halt_response?(response) && terminal_tool_stop_state(session).present?
  end

  def terminal_tool_stop_result(session)
    if part_run?(session)
      return finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: open_parts_response(session))
    end

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

  def handoff_requested?(session, response)
    halt_response?(response) && session[:context_wrapper].context[:pending_handoff]
  end

  def halt_response?(response)
    response.is_a?(RubyLLM::Tool::Halt)
  end

  def handle_handoff(session)
    next_agent, target_name = handoff_target(session)
    return missing_agent_result(session, target_name) unless next_agent
    return self_handoff_result(session, next_agent) if self_handoff?(session, next_agent)
    context = session[:context_wrapper].context
    if context[:handoff_count].to_i >= 2 || context[:previous_handoff_source_id] == next_agent.assistant_id
      record_transfer_guard(session, 'handoff_limit', next_agent)
      return continue_after_transfer_guard(session)
    end

    persist_handoff_state(session, next_agent)
    reset_session_for_handoff!(session, next_agent)
    nil
  end

  def handoff_target(session)
    pending_handoff = session[:context_wrapper].context.delete(:pending_handoff).to_h.with_indifferent_access
    raw_target = pending_handoff[:target_agent]
    target_name = handoff_target_name(raw_target)

    [session[:registry][target_name], target_name]
  end

  def handoff_target_name(raw_target)
    return raw_target.name.to_s if raw_target.respond_to?(:name)

    raw_target.to_s
  end

  def missing_agent_result(session, target_name)
    record_transfer_guard(session, 'target_missing')
    return continue_after_transfer_guard(session) if part_run?(session)

    message = target_name.present? ? "Handoff failed: Agent '#{target_name}' not found in registry" : 'Handoff failed: target agent is missing'
    error = AgentNotFoundError.new(message)
    finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: nil, error: error)
  end

  def self_handoff?(session, next_agent)
    current_agent = session[:current_agent]
    next_agent.equal?(current_agent) || next_agent.name == current_agent.name
  end

  def self_handoff_result(session, next_agent)
    record_transfer_guard(session, 'self_transfer', next_agent)
    return continue_after_transfer_guard(session) if part_run?(session)

    error = SelfHandoffError.new("Agent #{next_agent.name} attempted to hand off to itself")
    finalize_run(session[:chat], session[:context_wrapper], session[:current_agent], output: nil, error: error)
  end

  def record_transfer_guard(session, reason, target = nil)
    Captain::Runtime::CoordinationEvents.publish(
      'agent.transfer_guard', context: session[:context_wrapper].context, reason: reason,
      from_agent_id: session[:current_agent].assistant_id, to_agent_id: target&.assistant_id
    )
  end

  def persist_handoff_state(session, next_agent)
    context = session[:context_wrapper].context
    context[:handoff_count] = context[:handoff_count].to_i + 1
    context[:previous_handoff_source_id] = session[:current_agent].assistant_id
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
    context_wrapper.context.delete(:pending_handoff)
  end

  def track_usage(response, context_wrapper)
    context_wrapper&.usage&.add(response)
  end
end
