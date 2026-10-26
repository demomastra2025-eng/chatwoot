# frozen_string_literal: true

# The run state of one patient turn: the durable session, the agents of the channel and the activation of the agent that answers.
# #prepare reads the session and the history and never chooses an agent: the router decides who answers (see
# Captain::Runtime::DecisionRouter and Captain::Runtime::TurnDispatcher), and #activate prepares the chosen agent. The assistant
# the run was started with (`entry`) is the technical anchor of the channel, never a default agent: the router always names who
# answers (see DecisionRouter::Questions).
class Captain::AgentRunContext
  # sticky_agent_id: the agent that leads the dialog of a reply suggestion (Captain::ReplySuggestion::StickyAgent); while it is a
  # candidate it is the current agent and the holder of the run, whatever the saved session says.
  def initialize(entry:, conversation: nil, playground: nil, fence: {}, ephemeral_session: false, sticky_agent_id: nil) # rubocop:disable Metrics/ParameterLists
    @entry = entry
    @conversation = conversation
    @playground = playground
    @sticky_agent_id = sticky_agent_id.presence&.to_i
    @graph = Captain::AgentGraph.new(
      entry,
      inbox: conversation&.inbox || playground&.routing_inbox,
      standalone: conversation.nil? && playground.nil?
    )
    session_options = { entry: entry, conversation: conversation, playground: playground, fence: fence }
    session_options[:ephemeral] = true if ephemeral_session
    @session = Captain::Conversation::AgentSession.new(**session_options)
  end

  # graph: the agents of the channel. holder: the agent that holds the conversation as the response builder checks it
  # (Captain::Conversation::AgentOwnership), set by #prepare: the sticky agent of a reply suggestion while it is a candidate, else
  # the saved holder while it is an agent of the channel (a candidate of the router or not), else the anchor. Every response that
  # no chosen agent produced (a blocked input, a router failure, a council that could not be set up, a staff request, a custom
  # input rule) answers as the holder; otherwise the response builder drops it as stale.
  attr_reader :graph, :holder

  def prepare(context)
    context.delete(:captain_faq_outcome)
    context[:agent_request_id] ||= SecureRandom.uuid
    @playground_overrides = context.fetch(:state, {}).slice(:playground_thinking_effort)
    saved = @session.read
    raise ArgumentError, 'The entry agent is disabled' unless graph.find(@entry.id)

    sticky = sticky_candidate
    @holder = sticky || holder_of(saved)
    current = sticky || current_candidate(saved, context)
    context[:routing_current_agent_id] = current&.id
    context[:routing_trail] = Array(saved['routing_trail'])
    context[:agent_graph] = graph.solo? ? [] : graph.payload
    context[:agent_graph_object] = graph
    context[:agent_run_context_object] = self
    context[:agent_inbox_id] = graph.inbox&.id
    context[:agent_session] = @session
    context[:parts] = saved['parts'] || []
    # What the agents already did in this conversation (see Captain::DoneActions): the prompt of every agent that takes the turn.
    context[:done_actions] = Array(saved['done'])
    close_handed_off_history!(context, current || @entry)
    context[:state][:entry_assistant_id] = @entry.id
    context[:state][:agent_graph_ids] = graph.candidates.map(&:id)
    # A lone agent needs no decision: it answers, and it is prepared now.
    activate(graph.candidates.first, context) if graph.solo?
    context
  end

  # The chosen agent takes the turn: its configuration, its runtime preferences and the public history (never another agent's
  # private retrievals or provider reasoning).
  def activate(actor, context)
    state = context[:state] ||= {}
    previous_id = state[:assistant_id]
    state[:assistant_id] = actor.id
    state[:mesh_routing] = true
    state[:assistant_config] = actor.config
    prior_runtime = state[:captain_runtime]
    state[:captain_runtime] = Captain::AssistantSafetyPreferences.for(assistant: actor, feature: :assistant)
    state[:captain_runtime]['assistant_thinking_effort'] = actor.config['thinking_effort'] if actor.config['thinking_effort'].present?
    apply_playground_effort(state, actor, previous_id, prior_runtime)
    state[:prompt_context] = actor.prompt_context_state(state)
    context[:current_agent] = "assistant_#{actor.id}"
    context[:acting_assistant_id] = actor.id
    @playground&.activate_agent!(actor)
    state[:playground] = @playground.context_reference if @playground
    Current.executed_by = actor if @conversation
    return unless previous_id.present? && previous_id != actor.id

    context[:conversation_history] = public_history(context[:conversation_history])
    clear_actor_caches(context)
  end

  # The agents of the channel as runtime agents, built lazily: only the agent that answers builds its tools.
  def runtime_agents(overrides: {})
    shared_options = overrides.to_h.symbolize_keys.slice(:read_only_tools, :suggestion_tools)
    graph.candidates.map do |actor|
      # Playground model controls affect the agent that is being tried out; in a live run there are none.
      options = playground_target?(actor) ? overrides : shared_options
      Captain::Runtime::LazyAgent.new(actor, options: options).tap do |runtime_agent|
        runtime_agent.context_preparer = ->(wrapper) { activate(actor, wrapper.context) }
      end
    end
  end

  private

  # A saved holder that is no longer an agent of the channel at all (switched off, removed) is released in the session: the
  # conversation is then the anchor's for the response builder, until the router gives it to an agent.
  def holder_of(saved)
    saved_id = saved['current_assistant_id'].presence&.to_i
    return @entry unless saved_id

    found = graph.find(saved_id)
    return found if found

    @session.release_holder(saved_id)
    @entry
  end

  # The sticky agent of a reply suggestion, when it is a candidate of this channel (an agent of another inbox of the person's thread
  # is not).
  def sticky_candidate
    return unless @sticky_agent_id

    graph.candidates.find { |actor| actor.id == @sticky_agent_id }
  end

  # The agent that holds the conversation, when it is still a candidate. One that is no longer reachable (switched off, removed
  # from the channel, excluded) leaves the conversation without a current agent, and the router chooses again among all.
  def current_candidate(saved, context)
    saved_id = saved['current_assistant_id'].presence&.to_i
    return unless saved_id

    current = graph.candidates.find { |actor| actor.id == saved_id }
    return current if current

    Captain::Runtime::CoordinationEvents.publish('agent.reset', context: context, reason: 'agent_unavailable', from_agent_id: saved_id)
    nil
  end

  # The Playground thinking-effort control belongs to the agent the user is trying out: the assistant the session was opened with.
  def apply_playground_effort(state, actor, previous_id, prior_runtime)
    state.delete(:playground_thinking_effort)
    return unless playground_target?(actor)
    return keep_playground_effort(state, actor.id == previous_id, prior_runtime) unless @playground_overrides&.key?(:playground_thinking_effort)

    state[:playground_thinking_effort] = @playground_overrides[:playground_thinking_effort]
    state[:captain_runtime]['assistant_thinking_effort'] = state[:playground_thinking_effort]
  end

  # The same agent activated again in the same Playground run keeps the effort it already had.
  def keep_playground_effort(state, same_agent, prior_runtime)
    return unless @playground && same_agent && prior_runtime&.key?('assistant_thinking_effort')

    state[:captain_runtime]['assistant_thinking_effort'] = prior_runtime['assistant_thinking_effort']
  end

  def playground_target?(actor)
    actor.id == @entry.id
  end

  # A silent handoff leaves no public assistant reply in the transcript. When the conversation returns to the AI on a later
  # turn, close the earlier user message that was already handed off so the model does not treat it as an unanswered message of
  # the current turn.
  def close_handed_off_history!(context, actor)
    history = Array(context[:conversation_history])
    last = history.last
    return unless last && last[:role].to_s == 'user'

    # The history writes the message after its send time; the handoff record keeps the text alone.
    text = Captain::PromptClock.unstamped(last[:content].to_s).squish
    handoff = Array(context[:done_actions]).find do |entry|
      entry.to_h['tool'] == Captain::DoneActions::HANDOFF_TOOL &&
        (entry.to_h['user_message'].blank? || entry.to_h['user_message'].to_s.squish == text)
    end
    return unless handoff

    reason = handoff.to_h['text'].to_s
    note = reason.present? ? "Запрос передан специалистам: #{reason}." : 'Запрос передан специалистам.'
    context[:conversation_history] = history + [{ role: :assistant, content: note, agent_name: actor.agent_name }]
  end

  def public_history(history)
    Array(history).filter_map do |raw|
      message = raw.to_h.with_indifferent_access
      next unless %w[user assistant].include?(message[:role].to_s)
      next if message[:tool_calls].present?

      public = message.slice(:role, :content, :agent_name).symbolize_keys
      public[:content] = public_response(public[:content]) if message[:role].to_s == 'assistant'
      public
    end
  end

  def public_response(content)
    parsed = content.is_a?(String) ? JSON.parse(content) : content
    return parsed['response'].to_s if parsed.is_a?(Hash) && parsed.key?('response')

    content
  rescue JSON::ParserError
    content
  end

  def clear_actor_caches(context)
    %i[captain_v2_tool_result_cache captain_v2_tool_failure_cache captain_faq_outcome].each { |key| context.delete(key) }
  end
end
