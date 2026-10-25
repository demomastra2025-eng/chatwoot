# frozen_string_literal: true

# The check that a council runs exactly the agents the router chose: one part per participant, every participant a candidate of
# the turn, nobody else. It replaces the resolution of agent names that the models used to write: no model names an agent now.
module Captain::Runtime::CouncilPlan
  class MismatchError < ArgumentError; end

  module_function

  # parts: registry parts with integer executor_agent_id; agent_ids: the participants of the decision; candidate_ids: the agents
  # of the turn.
  def validate!(parts, agent_ids, candidate_ids:)
    wanted = Array(agent_ids).map(&:to_i).sort
    executors = Array(parts).map { |part| part.to_h.stringify_keys['executor_agent_id'].to_i }
    raise MismatchError, 'A council needs at least two participants' if wanted.uniq.size < 2
    raise MismatchError, 'A council participant is not an agent of this turn' unless (wanted - Array(candidate_ids).map(&:to_i)).empty?
    raise MismatchError, 'The council parts do not match the chosen participants' unless executors.sort == wanted

    parts
  end
end
