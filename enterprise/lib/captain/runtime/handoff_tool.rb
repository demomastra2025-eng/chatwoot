# frozen_string_literal: true

# The transfer of the conversation to one colleague: one tool per peer of the agent graph, with no parameters. The tool name
# identifies the colleague (Captain::HandoffNaming) and the description names it for the model, with what the colleague answers and
# what it can do. It needs no request plan: the plan only coordinates several agents (a council) or links an answer to an open part.
# The runner hands the whole conversation to the colleague, who continues it without mentioning the transfer.
#
# A transfer that cannot happen is told to the model as a result it can act on:
# - the message is already planned (plan_request ran in this turn): each agent of the plan answers its part;
# - the colleague is the one the conversation came from: the model chooses the colleague that owns the request, or answers itself.
# Only after two transfers in one run does the guard stop transfers for good (see Runner#continue_after_transfer_guard).
class Captain::Runtime::HandoffTool < Captain::Runtime::Tool
  PLANNED_MESSAGE = 'This message is already planned: each agent of the plan answers its part.'
  RETURN_TO_SOURCE = 'The conversation came from that colleague; transfer to the colleague who owns this request, or answer it yourself.'

  attr_reader :target_agent

  # The name the model calls the transfer to this colleague by. ChatFactory records the same name as bound.
  def self.tool_name_for(target_agent)
    record_id = target_agent.assistant_id if target_agent.respond_to?(:assistant_id)
    Captain::HandoffNaming.tool_name_for(target_agent.name, record_id: record_id)
  end

  def initialize(target_agent)
    @target_agent = target_agent
    @tool_name = self.class.tool_name_for(target_agent)
    display_name = target_agent.respond_to?(:display_name) ? target_agent.display_name : target_agent.name
    responsibility = target_agent.respond_to?(:routing_description) ? target_agent.routing_description.to_s.squish : ''
    @tool_description = transfer_description(display_name, responsibility, capabilities_of(target_agent))
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

    if context[:part_plan_accepted]
      record_guard(context, 'plan_accepted')
      return Captain::ToolResult.failure(error: PLANNED_MESSAGE, retryable: true)
    end

    if context[:agent_graph].present?
      source_id = context.dig(:state, :assistant_id)
      source = context[:agent_graph].find { |actor| actor[:id] == source_id }
      unless source && source[:id] != @target_agent.assistant_id &&
             context[:agent_graph].any? { |actor| actor[:id] == @target_agent.assistant_id }
        record_guard(context, 'target_not_allowed')
        return Captain::ToolResult.failure(error: 'This agent handoff is not allowed', retryable: false)
      end
      entry = Captain::Assistant.find_by(id: context.dig(:state, :entry_assistant_id), account_id: context.dig(:state, :account_id))
      inbox = Inbox.find_by(id: context[:agent_inbox_id], account_id: context.dig(:state, :account_id)) if context[:agent_inbox_id]
      graph = Captain::AgentGraph.new(entry, inbox: inbox) if entry
      unless graph && graph.allows?(graph.find(source_id), graph.find(@target_agent.assistant_id))
        record_guard(context, 'routing_changed')
        return Captain::ToolResult.failure(error: 'Agent routing changed; this handoff is no longer available', retryable: false)
      end
    end
    if context[:handoff_count].to_i >= Captain::Runtime::Runner::MAX_TRANSFERS
      record_guard(context, 'handoff_limit')
      context[:transfer_guard_active] = true
      return halt('')
    end
    if return_to_previous_source?(context)
      record_guard(context, 'return_to_previous_source')
      return Captain::ToolResult.failure(error: RETURN_TO_SOURCE, retryable: true)
    end
    tool_context.run_context.context[:pending_handoff] = {
      target_agent: @target_agent,
      timestamp: Time.current
    }

    halt('')
  end

  private

  # One sentence: whom the conversation goes to and what that colleague answers; then what that colleague can do.
  def transfer_description(display_name, responsibility, capabilities)
    title = %(Transfer the conversation to colleague "#{display_name.to_s.squish.tr('"', "'")}")
    text = responsibility.present? ? "#{title}: #{responsibility}" : "#{title}."
    return text if capabilities.blank?

    "#{text.end_with?('.', '!', '?') ? text : "#{text}."} #{capabilities}"
  end

  # The colleague's tool ids come without building its tools (a LazyAgent reads them from the assistant). A line is a help for the
  # choice of the colleague, never a reason to fail the build of the chat.
  def capabilities_of(target_agent)
    return '' unless target_agent.respond_to?(:tool_ids)

    Captain::Runtime::TransferCapabilities.line(target_agent.tool_ids)
  rescue StandardError
    ''
  end

  # An agent without an assistant ID has no routing identity, so it is never "the previous source".
  def return_to_previous_source?(context)
    target_id = @target_agent.assistant_id
    target_id.present? && context[:previous_handoff_source_id] == target_id
  end

  def record_guard(context, reason)
    Captain::Runtime::CoordinationEvents.publish(
      'agent.transfer_guard', context: context, reason: reason,
      from_agent_id: context.dig(:state, :assistant_id), to_agent_id: @target_agent.assistant_id
    )
  end
end
