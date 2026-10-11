# frozen_string_literal: true

# A channel has one entry agent. Only explicitly reachable agents may participate
# in its conversation; being in the workspace alone never grants that access.
class Captain::AgentGraph
  MAX_AGENTS = 100

  def initialize(entry)
    @entry = entry
  end

  attr_reader :entry

  def agents
    @agents ||= begin
      found = {}
      pending = [entry]
      until pending.empty?
        actor = pending.shift
        next if actor.nil? || found.key?(actor.id) || !eligible?(actor)

        raise ArgumentError, 'Agent routing graph is too large' if found.size >= MAX_AGENTS

        found[actor.id] = actor
        pending.concat(actor.handoff_targets.to_a) if actor.external_agent?
      end
      found.values
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
    return false unless source && target && eligible?(source) && eligible?(target)

    source.handoff_targets.exists?(id: target.id)
  end

  def payload
    agents.map do |actor|
      { id: actor.id, key: "assistant_#{actor.id}", name: actor.name,
        description: actor.routing_description.to_s,
        target_ids: actor.handoff_targets.pluck(:id) & agents.map(&:id) }
    end
  end

  private

  def eligible?(actor)
    actor.account_id == entry.account_id && actor.active? && (actor.external_agent? || actor.id == entry.id)
  end
end
