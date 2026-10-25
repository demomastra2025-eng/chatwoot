# frozen_string_literal: true

# The agents of one channel. A text channel reaches every active external agent of the workspace; a voice channel and a run
# without a channel have their assigned agent only. The assistant the channel is bound to (`entry`) is a technical anchor of
# the channel (who the job runs as, whose account settings apply): it is not a main agent and has no routing role. Who answers a
# patient turn is decided by Captain::Runtime::DecisionRouter among the candidates, all of them peers.
class Captain::AgentGraph
  MAX_AGENTS = 100

  # The channel's anchor assistant is switched off, so the channel has no agents. Callers that only ask "who may act" treat this
  # as "nobody"; it stays an ArgumentError for the others.
  class EntryDisabledError < ArgumentError; end

  def initialize(entry, inbox: nil, standalone: false)
    @entry = entry
    @inbox = inbox
    @standalone = standalone
  end

  attr_reader :entry, :inbox

  # Every agent that may act in this channel (ownership, fences, parts): the anchor and the channel members.
  def agents
    @agents ||= begin
      raise EntryDisabledError, 'The entry agent is disabled' unless entry.active?

      members = [entry] + channel_members.reject { |actor| actor.id == entry.id }
      raise ArgumentError, 'Agent routing graph is too large' if members.size > MAX_AGENTS

      members.sort_by(&:id)
    end
  end

  def find(id)
    agents.find { |actor| actor.id == id.to_i }
  end

  # The agents the router chooses among for a patient turn: patient-facing (an internal assistant such as Workspace MCP is not a
  # channel member), not excluded by the platform (config patient_routing false), and with a competence card to be chosen by.
  # A channel left with no such agent (a voice channel, an internal anchor, agents without cards) has its anchor answer alone.
  def candidates
    @candidates ||= begin
      routable = agents.select { |actor| actor.external_agent? && actor.config.to_h['patient_routing'] != false }
      described = routable.select { |actor| actor.routing_description.to_s.strip.present? }
      described.presence || [entry]
    end
  end

  # One candidate or none: nothing to choose, the router is not called.
  def solo?
    candidates.size < 2
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

  private

  # For an external agent on a text channel or in the workspace sandbox, every active external agent is a member.
  def channel_members
    return [] if @standalone
    return [] unless entry.external_agent?

    return [] if inbox&.channel_type == 'Channel::Voice'

    Captain::Assistant.entry_eligible.where(account_id: entry.account_id).order(:id).to_a
  end
end
