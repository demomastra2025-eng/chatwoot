# frozen_string_literal: true

# Applies the router's decision to the turn (see Captain::Runtime::DecisionRouter), once, before any agent runs:
#   stay_current / route_agent_<id>  the agent holds the conversation (persisted with the routing revision), its own open parts are
#                                    continued in the conversation, it is activated and runs alone: no transfers within the run
#   council_<ids>                    the message is cut into one part per participant (CouncilSplitter), the council is accepted
#                                    with exactly those participants (CouncilPlan) and runs; the current agent keeps the
#                                    conversation, or the first participant takes it when no agent held it yet
#   no_reply_needed                  the message needs no answer: the agent that leads the dialog (else the holder of the
#                                    conversation) keeps it and may write a short courtesy reply or nothing; its action tools
#                                    refuse on this turn (ToolWrapper::ACKNOWLEDGEMENT_TURN_KEY), and the trail records no route
#   one agent only                   no decision: the agent of the channel answers
# A staff request (human_handoff) never reaches the dispatcher: no agent runs for it (see AgentRunnerService). Neither does
# no_reply_needed in a reply suggestion: no agent drafts it.
class Captain::Runtime::TurnDispatcher
  # The council could not be set up (the participants of the split do not match the decision): a failure of the turn.
  class CouncilUnavailable < StandardError; end

  # graph: Captain::AgentGraph of the turn; run_context: Captain::AgentRunContext (activates the chosen agent). routing: decision
  # (nil for a channel with one agent), router (the Captain::Runtime::DecisionRouter of the turn, for the re-decision of a council
  # part), snapshot (its RoutingSnapshot) and request_id (shared by the events of the decision).
  def initialize(graph:, run_context:, account:, routing: {})
    @graph = graph
    @run_context = run_context
    @account = account
    @decision = routing[:decision]
    @router = routing[:router]
    @snapshot = routing[:snapshot]
    @routing_request_id = routing[:request_id]
  end

  attr_reader :decision

  def council?
    @decision&.council? == true
  end

  def prepare!(context)
    if @decision.nil?
      prepare_single_agent(context)
    elsif @decision.no_reply?
      prepare_no_reply(context)
    elsif council?
      prepare_council(context)
    else
      prepare_agent(context)
    end
    context
  end

  # agent_runner: Captain::Runtime::AgentRunner of the turn (its registry holds the agents of the channel, built lazily).
  def run(agent_runner, input, context:, max_turns:, runtime_options:)
    return agent_runner.run(input, context: context, max_turns: max_turns, runtime_options: runtime_options) unless council?

    council = { parts: Array(context.dig(:part_plan, :parts)), acting_agent_key: context[:current_agent], reassigner: reassigner(context) }
    agent_runner.run_council(input, council: council, context: context, runtime_options: runtime_options)
  end

  private

  # The channel has one agent: it was activated when the context was prepared. It holds the conversation.
  def prepare_single_agent(context)
    actor = @graph.candidates.first
    Captain::Runtime::RoutingState.new(context).persist!(actor_id: actor.id)
  end

  def prepare_agent(context)
    actor = @graph.find(@decision.agent_id) || raise(Captain::Runtime::Runner::AgentNotFoundError, 'The chosen agent is not reachable')
    from_id = context[:routing_current_agent_id]
    Captain::Runtime::RoutingState.new(context).persist!(actor_id: actor.id, trail: { kind: 'agent', from: from_id, to: [actor.id] })
    Captain::Runtime::RoutingEvents.transfer(context: context, from_agent_id: from_id, to_agent_id: actor.id) if from_id.present?
    Captain::Runtime::PartRegistry.new(context).absorb_open_parts!(actor.id)
    @run_context.activate(actor, context)
  end

  # A live turn that needs no answer (a plain thanks, ok, goodbye or emoji): no route, no transfer and no open part changes hands.
  def prepare_no_reply(context)
    actor = @graph.find(@decision.agent_id) || @run_context.holder ||
            raise(Captain::Runtime::Runner::AgentNotFoundError, 'No agent holds the conversation')
    Captain::Runtime::RoutingState.new(context).persist!(actor_id: actor.id)
    context[Captain::Runtime::ToolWrapper::ACKNOWLEDGEMENT_TURN_KEY] = true
    @run_context.activate(actor, context)
  end

  def prepare_council(context)
    parts = council_parts(context)
    current_id = context[:routing_current_agent_id]
    acting_id = current_id.presence || parts.first['executor_agent_id']
    acting = @graph.find(acting_id) || raise(CouncilUnavailable, 'The acting agent of the council is not reachable')
    Captain::Runtime::RoutingState.new(context).persist!(
      actor_id: (acting.id if current_id.blank?), trail: { kind: 'council', from: current_id, to: @decision.agent_ids }
    )
    @run_context.activate(acting, context)
    accept_council(context, parts)
  end

  def council_parts(context)
    result = Captain::Runtime::CouncilSplitter.new(
      account: @account, message: council_message(context), participants: @decision.agent_ids.map { |id| participant(id) },
      open_questions: Array(@snapshot&.open_questions), observability: observability(context)
    ).split
    context[:council_split] = { parts_count: result.parts.size, fallback: result.fallback, reason: result.reason }.compact
    result.parts.map { |part| with_link(part, context) }
  end

  def accept_council(context, parts)
    candidate_ids = @graph.candidates.map(&:id)
    Captain::Runtime::PartRegistry.new(context).accept!(mode: 'council', parts: parts) do |items|
      Captain::Runtime::CouncilPlan.validate!(items, @decision.agent_ids, candidate_ids: candidate_ids)
    end
  rescue Captain::Runtime::CouncilPlan::MismatchError => e
    raise CouncilUnavailable, e.message
  end

  # The open question the splitter linked, by its number, as the stored part id the registry continues.
  def with_link(part, context)
    number = part.delete('link_part_number')
    return part if number.blank?

    part.merge('link_part_id' => Captain::Runtime::PartRegistry.part_id_for(context[:parts], number))
  end

  # The council part that answered "not mine" is decided again by the router on its own words; the event is published here.
  def reassigner(context)
    return unless @router

    lambda do |fragment:, without:|
      decision = @router.redecide(fragment: fragment, without: without)
      if decision
        Captain::Runtime::RoutingEvents.routed(context: context, decision: decision, from_agent_id: Array(without).first,
                                               routing_request_id: @routing_request_id)
      end
      decision
    end
  end

  def participant(id)
    @snapshot&.agent(id) ||
      Captain::Runtime::RoutingSnapshot::Agent.new(id: id, label: Captain::Routing::CompetenceCard.label(@graph.find(id)&.name), card: '')
  end

  def council_message(context)
    @snapshot&.latest_message.presence || Captain::Runtime::RoutingSnapshot.text_of(context[:captain_v2_current_input])
  end

  def observability(context)
    state = context[:state].to_h
    conversation = state[:conversation].to_h
    { account_id: @account&.id, assistant_id: state[:assistant_id], conversation_record_id: conversation[:id],
      conversation_display_id: conversation[:display_id], source: state[:source], session_id: context[:session_id],
      routing_request_id: @routing_request_id }.compact
  end
end
