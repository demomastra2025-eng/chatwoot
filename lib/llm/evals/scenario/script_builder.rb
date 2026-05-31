# frozen_string_literal: true

class Llm::Evals::Scenario::ScriptBuilder
  DEFAULT_AUTOPILOT_TURNS = 5

  def initialize(attributes:)
    @attributes = attributes
  end

  def call
    return @attributes.fetch(:script) if @attributes.key?(:script)
    return autopilot_script if truthy?(@attributes[:autopilot])

    @attributes.fetch(:script)
  end

  private

  def autopilot_script
    [{ proceed: { turns: autopilot_turns } }]
  end

  def autopilot_turns
    normalized_turns = @attributes[:autopilot_turns].to_i
    normalized_turns.positive? ? normalized_turns : DEFAULT_AUTOPILOT_TURNS
  end

  def truthy?(value)
    value == true || value.to_s == 'true'
  end
end
