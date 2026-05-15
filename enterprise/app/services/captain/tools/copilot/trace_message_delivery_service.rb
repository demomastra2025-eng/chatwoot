# frozen_string_literal: true

class Captain::Tools::Copilot::TraceMessageDeliveryService < Captain::Tools::Copilot::BaseObservabilityService
  def self.name
    'trace_message_delivery'
  end

  description 'Trace outbound and incoming message delivery for one permissible account conversation'
  param :conversation_id, type: :integer, desc: 'Conversation display ID or internal ID.', required: true
  param :limit, type: :number, desc: 'Maximum number of recent messages to return. Capped at 100.', required: false

  def execute(conversation_id:, limit: nil)
    conversation = find_permissible_conversation!(conversation_id)
    messages = conversation.messages.reorder(created_at: :desc, id: :desc).limit(observability_limit(limit)).to_a.reverse

    formatted_payload(
      account_id: account.id,
      conversation: conversation_payload(conversation),
      summary: delivery_summary(messages),
      messages: messages.map { |message| message_delivery_payload(message) }
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def conversation_payload(conversation)
    {
      id: conversation.id,
      display_id: conversation.display_id,
      status: conversation.status,
      inbox_id: conversation.inbox_id,
      inbox_name: conversation.inbox&.name,
      channel_type: conversation.inbox&.channel_type,
      contact_id: conversation.contact_id,
      contact_name: conversation.contact&.name,
      assignee_id: conversation.assignee_id,
      team_id: conversation.team_id,
      last_activity_at: conversation.last_activity_at&.iso8601
    }
  end

  def delivery_summary(messages)
    outgoing = messages.select(&:outgoing?)

    {
      total_messages: messages.size,
      outgoing_count: outgoing.size,
      failed_outgoing_count: outgoing.count(&:failed?),
      delivered_outgoing_count: outgoing.count(&:delivered?),
      read_outgoing_count: outgoing.count(&:read?)
    }
  end

  def message_delivery_payload(message)
    {
      id: message.id,
      created_at: message.created_at&.iso8601,
      message_type: message.message_type,
      status: message.status,
      content_type: message.content_type,
      private: message.private,
      sender_type: message.sender_type,
      sender_id: message.sender_id,
      source_id: message.source_id,
      external_error: external_error_for(message)
    }.compact
  end
end
