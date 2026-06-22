links_by_conversation_id = @accessible_links_by_thread_id.fetch(@communication_thread.id, []).index_by(&:conversation_id)

json.meta do
  json.contact do
    json.partial! 'api/v1/models/contact', formats: [:json], resource: @communication_thread.contact
  end
  json.channels do
    json.array! @channel_capabilities_by_thread_id.fetch(@communication_thread.id, []) do |channel|
      json.partial! 'api/v1/accounts/communication_threads/partials/channel', formats: [:json], channel: channel
    end
  end
  json.first_unread_message_id @first_unread_message_id
end

json.payload do
  json.array! @messages do |message|
    link = links_by_conversation_id[message.conversation_id]
    json.partial! 'api/v1/models/message', message: message
    json.communication_thread_id @communication_thread.display_id
    json.inbox_name link&.inbox&.name || message.inbox&.name
    json.channel link&.inbox&.channel_type || message.inbox&.channel_type
    json.medium message.inbox&.channel.respond_to?(:medium) ? message.inbox.channel.medium : nil
    json.contact_inbox_id link&.contact_inbox_id || message.conversation&.contact_inbox_id
  end
end
