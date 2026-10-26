# frozen_string_literal: true

# The platform settings of the router (installation config only: clinics never choose them, and there is no per-account switch).
# A blank, unreadable or out-of-range value gives the built-in default. The router has no confidence threshold and no escalation
# since 26.10 (the decision models' most probable answer decides): the old rows CAPTAIN_AGENT_ROUTING_MIN_CONFIDENCE,
# _HUMAN_MIN_CONFIDENCE, _ESCALATION_*, _SUGGESTION_ESCALATION_* and _BOUNCE_ESCALATION are not read.
module Captain::Runtime::DecisionRouter::Settings
  # Three full attempts of the routing chain (2 s each, the turn decision profile) plus overhead, so the third model is never cut short.
  CHAIN_BUDGET_SECONDS = 6.5

  module_function

  def chain_budget_seconds
    milliseconds('CAPTAIN_AGENT_ROUTING_CHAIN_BUDGET_MS', CHAIN_BUDGET_SECONDS, max: 15)
  end

  def milliseconds(name, default, max:)
    value = number(name)
    value.positive? ? [value / 1000.0, max].min : default
  end

  # The setting as a number; 0 when it is blank or not a number.
  def number(name)
    Float(read(name).to_s.strip, exception: false) || 0
  end

  def read(name)
    InstallationConfig.find_by(name: name)&.value
  rescue StandardError
    nil
  end
end
