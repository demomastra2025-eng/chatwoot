# frozen_string_literal: true

# A late outcome remains tied to the request part that caused it, even if a
# different specialist now owns the conversation.
class Captain::Conversation::PartDeliveryGuard
  def self.current?(conversation:, assistant:, part_id:, version:, allow_unknown: false)
    entry = conversation.inbox&.captain_assistant
    return false unless entry && assistant.account_id == conversation.account_id
    return false unless Captain::AgentGraph.new(entry, inbox: conversation.inbox).find(assistant.id)

    session = Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).read
    part = Array(session['parts']).find { |item| item['id'] == part_id }
    part && part['version'].to_i == version.to_i && part['executor_agent_id'].to_i == assistant.id && part['cancelled'] != true &&
      part['state'] != 'failed' && (allow_unknown || part['state'] != 'unknown')
  rescue ActiveRecord::RecordNotFound, ArgumentError
    false
  end
end
