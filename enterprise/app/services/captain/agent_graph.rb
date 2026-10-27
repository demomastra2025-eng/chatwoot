# frozen_string_literal: true

# The agents of one channel (see Captain::ChannelScope). A text channel reaches every enabled external agent of the workspace; a
# voice channel has the voice agent of its number alone. All of them are peers: there is no main agent and no anchor. Who answers a
# patient turn is decided by Captain::Runtime::DecisionRouter among the candidates. When there is nobody to choose, the graph is empty
# and the caller turns that into an outcome (see #unavailable_reason); nothing answers in the place of a missing agent.
class Captain::AgentGraph
  MAX_AGENTS = 100
  NO_ACTIVE_AGENT = :no_active_agent
  NO_ROUTING_CARDS = :no_routing_cards

  def initialize(scope)
    @scope = scope
  end

  attr_reader :scope

  delegate :account, :inbox, to: :scope

  # Every agent that may act in this channel (ownership, fences, parts): the enabled external agents of the channel.
  def agents
    @agents ||= begin
      members = scope.members
      raise ArgumentError, 'Agent routing graph is too large' if members.size > MAX_AGENTS

      members.sort_by(&:id)
    end
  end

  def find(id)
    agents.find { |actor| actor.id == id.to_i }
  end

  # The agents the router chooses among for a patient turn: the enabled external agents that have a competence card to be chosen by.
  # A workspace with one enabled agent has no choice to make, so that agent answers whether or not it has a card. With two or more
  # enabled agents, those without a card are not chosen, and when none has a card nobody answers (see #unavailable_reason).
  def candidates
    @candidates ||= begin
      routable = agents.select(&:external_agent?)
      routable.size == 1 ? routable : routable.select { |actor| actor.routing_description.to_s.strip.present? }
    end
  end

  # One candidate or none: nothing to choose, the router is not called.
  def solo?
    candidates.size < 2
  end

  # Why nobody can answer here, or nil when somebody can: every agent is off, or several are on and none has a card to be chosen by.
  def unavailable_reason
    return NO_ACTIVE_AGENT if agents.empty?

    NO_ROUTING_CARDS if candidates.empty?
  end

  def candidate_rows
    candidates.map { |actor| Captain::Routing::Candidate.from_assistant(actor) }
  end

  # An agent by its key: assistant_<id> (the runtime key) or agent_<id> (as it appears in a stored tool name), a legacy
  # scenario key, or its normalized name. A key that still carries a former transfer prefix (a stored tool name) is read as well.
  def resolve(key)
    key = Captain::HandoffNaming.target_key_for(key) || key.to_s
    agent_id = Captain::HandoffNaming.agent_id_from_key(key)
    return find(agent_id) if agent_id

    legacy_id = key[/\Ascenario_(\d+)_/, 1]
    return agents.find { |actor| actor.legacy_scenario_id == legacy_id.to_i } if legacy_id

    agents.find { |actor| Captain::HandoffNaming.safe_target_name(actor.name, record_id: actor.id) == key }
  end

  # The candidates as the run context lists them (who may own a council part): ids and names, no descriptions.
  def payload
    candidates.map { |actor| { id: actor.id, key: "assistant_#{actor.id}", name: actor.name } }
  end
end
