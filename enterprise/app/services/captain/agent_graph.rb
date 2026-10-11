# frozen_string_literal: true

# A channel has one entry agent. Its active members form a direct mesh.
class Captain::AgentGraph
  MAX_AGENTS = 100

  def initialize(entry, inbox: nil)
    @entry = entry
    @inbox = inbox
  end

  attr_reader :entry, :inbox

  def agents
    @agents ||= begin
      raise ArgumentError, 'The entry agent is disabled' unless entry.active?

      members = if entry.external_agent?
                  Captain::Assistant.entry_eligible.where(account_id: entry.account_id).order(:id).select do |actor|
                    inbox.nil? || actor.works_on_inbox?(inbox)
                  end
                else
                  [entry]
                end
      members = [entry] + members.reject { |actor| actor.id == entry.id }
      raise ArgumentError, 'Agent routing graph is too large' if members.size > MAX_AGENTS

      members
    end
  end

  def find(id)
    agents.find { |actor| actor.id == id.to_i }
  end

  def resolve(key)
    key = key.to_s
    return find(key.delete_prefix('assistant_')) if key.match?(/\Aassistant_\d+\z/)

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
end
