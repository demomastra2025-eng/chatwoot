link = @accessible_links_by_thread_id.fetch(@communication_thread.id, []).find { |thread_link| thread_link.conversation_id == @message.conversation_id }
message_inbox = @message.inbox
message_medium = message_inbox&.channel.respond_to?(:medium) ? message_inbox.channel.medium : nil

json.partial! 'api/v1/models/message', message: @message
json.communication_thread_id @communication_thread.display_id
json.inbox_name link&.inbox&.name || message_inbox&.name
json.channel link&.inbox&.channel_type || message_inbox&.channel_type
json.medium message_medium
json.contact_inbox_id link&.contact_inbox_id || @message.conversation&.contact_inbox_id
json.communication_thread do
  json.partial! 'api/v1/accounts/communication_threads/partials/communication_thread',
                formats: [:json],
                communication_thread: @communication_thread,
                links: @accessible_links_by_thread_id.fetch(@communication_thread.id, []),
                channels: @channel_capabilities_by_thread_id.fetch(@communication_thread.id, []),
                last_public_message: @last_public_messages_by_thread_id[@communication_thread.id],
                last_non_activity_message: @last_non_activity_messages_by_thread_id[@communication_thread.id],
                crm_deal_stages_by_communication_thread_id: @crm_deal_stages_by_communication_thread_id
end
