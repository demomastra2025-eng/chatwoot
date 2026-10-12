# frozen_string_literal: true

# A channel has one entry agent (the main agent of the channel grid). The
# peers are the active agents the grid attaches to that channel, and together
# they form a direct mesh. No per-agent allowed-targets list restricts it.
# Without a channel (no inbox) there is no grid, so the entry agent works alone
# and has no peers.
class Captain::AgentGraph
  MAX_AGENTS = 100

  # The channel's entry agent is switched off, so no routing exists. Callers that only
  # ask "who may act" treat this as "nobody"; it stays an ArgumentError for the others.
  class EntryDisabledError < ArgumentError; end

  def initialize(entry, inbox: nil)
    @entry = entry
    @inbox = inbox
  end

  attr_reader :entry, :inbox

  def agents
    @agents ||= begin
      raise EntryDisabledError, 'The entry agent is disabled' unless entry.active?

      members = [entry] + channel_members.reject { |actor| actor.id == entry.id }
      raise ArgumentError, 'Agent routing graph is too large' if members.size > MAX_AGENTS

      members
    end
  end

  def find(id)
    agents.find { |actor| actor.id == id.to_i }
  end

  # Another agent works on this channel. Only then is there anyone to transfer
  # to, consult or plan with: a lone agent (the main one) gets no routing,
  # council or transfer prompts and tools at all.
  def peers?
    agents.size > 1
  end

  # An agent by its key: assistant_<id> (the runtime key) or agent_<id> (as it appears in a transfer tool name), a legacy
  # scenario key, or its normalized name. A key that still carries a transfer prefix (a stored tool name) is read as well.
  def resolve(key)
    key = Captain::HandoffNaming.target_key_for(key) || key.to_s
    agent_id = Captain::HandoffNaming.agent_id_from_key(key)
    return find(agent_id) if agent_id

    legacy_id = key[/\Ascenario_(\d+)_/, 1]
    return agents.find { |actor| actor.legacy_scenario_id == legacy_id.to_i } if legacy_id

    agents.find { |actor| Captain::HandoffNaming.safe_target_name(actor.name, record_id: actor.id) == key }
  end

  def allows?(source, target)
    !!(source && target && source.id != target.id && find(source.id) && find(target.id))
  end

  def payload
    agents.map do |actor|
      { id: actor.id, key: "assistant_#{actor.id}", name: actor.name,
        description: actor.routing_description.to_s }
    end
  end

  private

  # The active external agents the grid attaches to this channel. Without a
  # channel, or for an agent that is not external, there is nobody else.
  def channel_members
    return [] unless inbox && entry.external_agent?

    Captain::Assistant.entry_eligible.where(account_id: entry.account_id).order(:id).select do |actor|
      actor.works_on_inbox?(inbox)
    end
  end
end
