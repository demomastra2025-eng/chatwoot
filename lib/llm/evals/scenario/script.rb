# frozen_string_literal: true

class Llm::Evals::Scenario::Script
  Step = Struct.new(:type, :payload, keyword_init: true)

  STEP_KEYS = %i[
    user assistant agent tool_started tool_completed tool_failed message judge assert proceed succeed fail
  ].freeze

  attr_reader :steps

  def initialize(raw_steps)
    @steps = Array(raw_steps).map { |step| normalize_step(step) }
  end

  private

  def normalize_step(step)
    return Step.new(type: 'user', payload: step) unless step.respond_to?(:to_h)

    payload = step.to_h.deep_symbolize_keys
    explicit_type = payload[:type].presence
    return Step.new(type: explicit_type.to_s, payload: payload.except(:type)) if explicit_type

    step_key = STEP_KEYS.find { |key| payload.key?(key) }
    return Step.new(type: step_key.to_s, payload: payload[step_key]) if step_key

    Step.new(type: 'message', payload: payload)
  end
end
