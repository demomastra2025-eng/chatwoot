# frozen_string_literal: true

class Captain::Runtime::HandoffTool < Captain::Runtime::Tool
  attr_reader :target_agent

  def initialize(target_agent)
    @target_agent = target_agent
    @tool_name = "handoff_to_#{normalize_name(target_agent.name)}"
    @tool_description = "Transfer conversation to #{target_agent.name}"
    super()
  end

  def name
    @tool_name
  end

  def description
    @tool_description
  end

  def perform(tool_context, **_params)
    tool_context.run_context.context[:pending_handoff] = {
      target_agent: @target_agent,
      timestamp: Time.current
    }

    halt("I'll transfer you to #{@target_agent.name} who can better assist you with this.")
  end

  private

  def normalize_name(value)
    value.to_s.parameterize(separator: '_')
  end
end
