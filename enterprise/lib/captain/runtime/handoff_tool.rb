# frozen_string_literal: true

class Captain::Runtime::HandoffTool < Captain::Runtime::Tool
  attr_reader :target_agent

  def initialize(target_agent)
    @target_agent = target_agent
    @tool_name = Captain::HandoffNaming.tool_name_for(target_agent.name)
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
    context = tool_context.run_context.context
    if context[:agent_graph].present?
      source_id = context.dig(:state, :assistant_id)
      source = context[:agent_graph].find { |actor| actor[:id] == source_id }
      unless source && source[:target_ids].include?(@target_agent.assistant_id)
        record_guard(context, 'target_not_allowed')
        return Captain::ToolResult.failure(error: 'This agent handoff is not allowed', retryable: false)
      end
      entry = Captain::Assistant.find_by(id: context.dig(:state, :entry_assistant_id), account_id: context.dig(:state, :account_id))
      graph = Captain::AgentGraph.new(entry) if entry
      unless graph && graph.allows?(graph.find(source_id), graph.find(@target_agent.assistant_id))
        record_guard(context, 'routing_changed')
        return Captain::ToolResult.failure(error: 'Agent routing changed; this handoff is no longer available', retryable: false)
      end
    end
    tool_context.run_context.context[:pending_handoff] = {
      target_agent: @target_agent,
      timestamp: Time.current
    }

    halt("I'll transfer you to #{@target_agent.name} who can better assist you with this.")
  end

  private

  def record_guard(context, reason)
    Captain::Runtime::CoordinationEvents.publish(
      'agent.transfer_guard', context: context, reason: reason,
      from_agent_id: context.dig(:state, :assistant_id), to_agent_id: @target_agent.assistant_id
    )
  end
end
