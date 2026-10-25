# frozen_string_literal: true

# The scope an action of the agent is claimed under (see Captain::Conversation::AgentSession#reserve_operation): the part of a
# council when the run works on one, else the patient request (the message the run answers).
module Captain::Runtime::OperationScope
  module_function

  def operation(context)
    return "part:#{context[:active_part_id]}:v#{context[:active_part_version]}" if context[:active_part_id].present?

    request(context)
  end

  def request(context)
    fence = context.dig(:state, :captain_response_fence).to_h.with_indifferent_access
    anchor = fence[:last_message_id].presence || context[:agent_request_id]
    "request:#{anchor}"
  end
end
