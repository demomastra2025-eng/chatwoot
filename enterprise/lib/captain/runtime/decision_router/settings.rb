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

  def escalation_timeout_seconds
    milliseconds('CAPTAIN_AGENT_ROUTING_ESCALATION_TIMEOUT_MS', ESCALATION_TIMEOUT_SECONDS, max: 60)
  end

  def escalation_effort
    value = read('CAPTAIN_AGENT_ROUTING_ESCALATION_EFFORT').to_s.strip.downcase
    EFFORTS.include?(value) ? value : ESCALATION_EFFORT
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
