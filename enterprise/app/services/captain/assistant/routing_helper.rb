# frozen_string_literal: true

# Who answers the patient turn (see Captain::Runtime::DecisionRouter). The state of the router is built on the calling thread
# (database reads only); the decision runs on a thread of its own, side by side with the platform safety check of the input, and
# the run waits for it before any agent is called (Captain::Runtime::RoutingRun). A clinic with one agent makes no decision. When
# the router cannot decide, the turn ends through the existing technical-failure path (the conversation goes to staff).
#
# CAPTAIN_ROUTER_PARALLEL=off runs the decision on the calling thread, after the safety check (the routing benchmark, which runs
# turns in a rolled-back transaction, sets it).
module Captain::Assistant::RoutingHelper
  PARALLEL_SWITCH = 'CAPTAIN_ROUTER_PARALLEL'

  private

  # Builds the state and starts the decision. Nothing is started for a clinic with one agent (or a run of one agent alone).
  # Until the decision is applied, the turn answers as the agent that holds the conversation (Captain::AgentRunContext#holder): a
  # blocked input, a router failure or a staff request then names the agent the session names, as the response builder requires, or
  # no agent when nobody holds the conversation (the AI itself).
  def start_routing(context)
    reset_routing_state
    return unless graph_run?

    @acting_assistant_id = conversation_holder&.id
    graph = agent_run_context.graph
    return if graph.solo?

    @routing_request_id = SecureRandom.uuid
    @routing_snapshot = Captain::Runtime::RoutingSnapshot.from_context(
      context, candidates: graph.candidate_rows, clinic: account&.name, patient_language: saved_patient_language,
               human_available: routing_human_available?,
               visit: Captain::Runtime::AgreedVisit.for(@conversation, now: patient_message_time)
    )
    @router = Captain::Runtime::DecisionRouter.new(@routing_snapshot, account: account,
                                                                      observability: routing_observability(context),
                                                                      request: { conversation: @conversation }.compact)
    @routing_run = Captain::Runtime::RoutingRun.new(@router, parallel: parallel_routing?)
  end

  # The moment the patient wrote the message the turn answers (now when the history carries no time): the visits that had not ended by
  # then are the ones the message can answer about (Captain::Runtime::AgreedVisit).
  def patient_message_time
    Captain::PromptClock.parse_time(@current_input_sent_at) || Time.current
  end

  # The decision of the turn (nil for a clinic with one agent). Raises Captain::Runtime::DecisionRouter::UnavailableError.
  def await_routing(context)
    return unless @routing_run

    decision = @routing_run.await
    publish_routed(context, decision)
    decision
  rescue Captain::Runtime::DecisionRouter::UnavailableError => e
    Captain::Runtime::RoutingEvents.failed(context: context, error: e, routing_request_id: @routing_request_id,
                                           from_agent_id: @routing_snapshot&.current_agent_id)
    raise
  end

  # Waits for a decision the turn started and did not await (an error before #await_routing); an abandoned one is not waited for.
  def settle_routing
    @routing_run&.settle
  end

  # The turn ends without the decision (a blocked input): nothing waits for it.
  def abandon_routing
    @routing_run&.abandon
  end

  def turn_dispatcher
    @turn_dispatcher ||= Captain::Runtime::TurnDispatcher.new(
      graph: agent_run_context.graph, run_context: agent_run_context, account: account,
      routing: { decision: @turn_decision, router: @router, snapshot: @routing_snapshot, request_id: @routing_request_id }
    )
  end

  # The router could not decide: no text for the patient, the conversation goes to staff with a note that names only codes.
  def routing_failure_response(error, context)
    technical_failure_response({ 'kind' => Captain::Runtime::ToolFailure::TECHNICAL, 'tool' => 'agent_router', 'reason' => error.reason },
                               context)
  end

  # The agent that holds the conversation (see Captain::AgentRunContext#holder), nil when nobody does; the agent of a run alone holds it.
  def conversation_holder
    return @assistant unless graph_run?

    agent_run_context.holder
  end

  def reset_routing_state
    @routing_snapshot = nil
    @routing_run = nil
    @router = nil
    @turn_decision = nil
    @turn_dispatcher = nil
    @routing_request_id = nil
  end

  def parallel_routing?
    Captain::Assistant::PatientLanguageHelper::OFF_VALUES.exclude?(ENV.fetch(PARALLEL_SWITCH, nil).to_s.strip.downcase)
  end

  # The language the conversation already has: the router never waits for the language decision of this turn.
  def saved_patient_language
    @language_detector&.safe_saved_language
  rescue StandardError
    nil
  end

  # Staff can take the conversation: a reply suggestion always offers it (the operator answers); a conversation when the agent that
  # would hand it over may hand conversations to staff: the agent that holds the conversation, else any agent of the channel.
  def routing_human_available?
    return true if suggestion_run?
    return false unless @conversation || @playground_session

    actors = [conversation_holder].compact.presence || agent_run_context.graph.candidates
    actors.any? { |actor| staff_handoff_allowed?(actor) }
  rescue StandardError
    false
  end

  def staff_handoff_allowed?(actor)
    actor.handoff_enabled? && Array(actor.selected_agent_tool_ids).include?('handoff')
  end

  def routing_observability(context)
    state = context[:state] || {}
    conversation = state[:conversation] || {}
    { account_id: state[:account_id], assistant_id: acting_agent_id, conversation_record_id: conversation[:id],
      conversation_display_id: conversation[:display_id], channel_type: state[:channel_type], source: state[:source],
      session_id: context[:session_id], routing_request_id: @routing_request_id }.compact
  end

  def publish_routed(context, decision)
    return unless decision

    context[:routing_decision] = decision.to_event_payload
    Captain::Runtime::RoutingEvents.routed(context: context, decision: decision, from_agent_id: @routing_snapshot&.current_agent_id,
                                           routing_request_id: @routing_request_id)
    @callbacks[:on_agent_routed]&.call(context[:routing_decision].merge(from_agent_id: @routing_snapshot&.current_agent_id), nil)
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Router] routed event failed error_class=#{e.class.name}")
  end
end
