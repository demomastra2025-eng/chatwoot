# frozen_string_literal: true

# The platform settings of the router (installation config only: clinics never choose them, and there is no per-account switch).
# A blank, unreadable or out-of-range value gives the built-in default.
module Captain::Runtime::DecisionRouter::Settings
  MIN_CONFIDENCE = 0.75
  HUMAN_MIN_CONFIDENCE = 0.80
  # Three full attempts of the routing chain (2 s each, the turn decision profile) plus overhead, so the third model is never cut short.
  CHAIN_BUDGET_SECONDS = 6.5
  # The slowest escalation of the router benchmark took 9.1 s; 15 s leaves it room.
  ESCALATION_TIMEOUT_SECONDS = 15.0
  ESCALATION_EFFORT = 'high'
  # A reply suggestion: the operator waits for the draft. In the suggestion eval of 26.10 the escalation ran in 35% of the routed
  # turns (p50 4.7 s, p90 7.9 s at high effort), it was all of the latency the router added (p50 8.8 -> 11.7 s), and it agreed
  # with the decision models in 34 of the 35 low-confidence turns; two escalations hit 15 s and left no draft. Past this timeout the
  # outcome of the decision models decides (DecisionRouter#chain_fallback).
  SUGGESTION_ESCALATION_TIMEOUT_SECONDS = 10.0
  SUGGESTION_ESCALATION_EFFORT = 'medium'
  EFFORTS = %w[low medium high].freeze
  OFF_VALUES = %w[off 0 false disabled no].freeze

  module_function

  def min_confidence
    probability('CAPTAIN_AGENT_ROUTING_MIN_CONFIDENCE', MIN_CONFIDENCE)
  end

  def human_min_confidence
    probability('CAPTAIN_AGENT_ROUTING_HUMAN_MIN_CONFIDENCE', HUMAN_MIN_CONFIDENCE)
  end

  def chain_budget_seconds
    milliseconds('CAPTAIN_AGENT_ROUTING_CHAIN_BUDGET_MS', CHAIN_BUDGET_SECONDS, max: 15)
  end

  # suggestion: the escalation of a reply suggestion (CAPTAIN_AGENT_ROUTING_SUGGESTION_ESCALATION_TIMEOUT_MS), else of a live turn.
  def escalation_timeout_seconds(suggestion: false)
    return milliseconds('CAPTAIN_AGENT_ROUTING_ESCALATION_TIMEOUT_MS', ESCALATION_TIMEOUT_SECONDS, max: 60) unless suggestion

    milliseconds('CAPTAIN_AGENT_ROUTING_SUGGESTION_ESCALATION_TIMEOUT_MS', SUGGESTION_ESCALATION_TIMEOUT_SECONDS, max: 60)
  end

  # suggestion: the escalation of a reply suggestion (CAPTAIN_AGENT_ROUTING_SUGGESTION_ESCALATION_EFFORT, high gives the effort of a
  # live turn back), else of a live turn.
  def escalation_effort(suggestion: false)
    name, default = if suggestion
                      ['CAPTAIN_AGENT_ROUTING_SUGGESTION_ESCALATION_EFFORT', SUGGESTION_ESCALATION_EFFORT]
                    else
                      ['CAPTAIN_AGENT_ROUTING_ESCALATION_EFFORT', ESCALATION_EFFORT]
                    end
    value = read(name).to_s.strip.downcase
    EFFORTS.include?(value) ? value : default
  end

  def bounce_escalation?
    OFF_VALUES.exclude?(read('CAPTAIN_AGENT_ROUTING_BOUNCE_ESCALATION').to_s.strip.downcase)
  end

  def probability(name, default)
    value = number(name)
    value.positive? && value <= 1 ? value : default
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
