# frozen_string_literal: true

# Decides whether the agent prompt may show an internal number. A number is shown only when a tool bound for the run takes
# that record's id as a required or main parameter. An optional link parameter (create_task.deal_id,
# create_appointment.crm_deal_id) does not count, and a run whose tools are unknown shows no number.
# The conversation number is taken by assign_conversation and by send_message_to_conversation (it has no default target in the
# agent runtime: without the number it fails with "Conversation not found").
module Captain::PromptNumbers
  TOOLS = {
    contact: %w[get_contact],
    conversation: %w[assign_conversation send_message_to_conversation],
    appointment: %w[get_appointment update_appointment cancel_appointment],
    deal: %w[get_deal update_deal transition_deal_stage list_deal_stages get_deal_timeline]
  }.freeze

  module_function

  def shown?(kind, bound_tool_ids)
    return false if bound_tool_ids.nil?

    TOOLS.fetch(kind.to_sym).intersect?(Array(bound_tool_ids).map(&:to_s))
  end
end
