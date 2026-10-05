# frozen_string_literal: true

# The model a Captain agent stores in its own config (captain_assistants.config -> model). It outranks every other layer:
# Agentable#agent_model reads it before the account choice, the installation rows and the code defaults, so a cut-over
# that moved only those would leave such an agent on its old model. The cut-over clears the key (the agent then follows
# the platform default, like an account does); a rollback puts back exactly the stored value.
class Llm::CaptainLunaRollout::AgentModels
  STORED_MODEL_SQL = "TRIM(COALESCE(config ->> 'model', '')) <> ''"

  # Only the agents that have a stored model; the others have nothing to clear or to restore.
  def snapshot(account_ids)
    with_stored_model(account_ids).order(:id).map do |agent|
      { id: agent.id, account_id: agent.account_id, before: agent.config['model'] }
    end
  end

  # The agents of the entries, locked in id order, as { id => agent }.
  def lock(entries)
    Captain::Assistant.where(id: entries.pluck(:id)).order(:id).lock.index_by(&:id)
  end

  # A stored model has to be the one of the snapshot; an absent one is the done state.
  def verify!(entries, agents)
    entries.each do |entry|
      agent = agents[entry[:id]]
      next if agent && [entry[:before], nil].include?(stored_model(agent))

      raise Llm::CaptainLunaRollout::StalePlan, "The model of agent #{entry[:id]} changed since the snapshot"
    end
  end

  # An agent that gained a model after the snapshot would keep it through the cut-over: the snapshot is stale.
  def verify_complete!(account_ids, entries)
    stray = with_stored_model(account_ids).where.not(id: entries.pluck(:id)).pick(:id)
    raise Llm::CaptainLunaRollout::StalePlan, "Agent #{stray} gained a model after the snapshot" if stray
  end

  # Returns the number of agents that were written.
  def clear!(entries, agents)
    write_models!(entries, agents) { |config, _entry| config.except('model') }
  end

  def restore!(entries, agents)
    write_models!(entries, agents) { |config, entry| config.merge('model' => entry[:before]) }
  end

  private

  def with_stored_model(account_ids)
    Captain::Assistant.where(account_id: account_ids).where(STORED_MODEL_SQL)
  end

  def stored_model(agent)
    agent.config.to_h['model'].presence
  end

  # Saved without validations: the agent validations (rules, tools, voice reference) are not the business of a model
  # switch and must not stop it. The row is re-read first, because the voice settings of the same agent are written
  # through another object of the cut-over.
  def write_models!(entries, agents)
    entries.count do |entry|
      agent = agents.fetch(entry[:id]).reload
      config = agent.config.to_h
      wanted = yield(config, entry)
      next false if wanted == config

      agent.config = wanted
      agent.save!(validate: false)
      true
    end
  end
end
