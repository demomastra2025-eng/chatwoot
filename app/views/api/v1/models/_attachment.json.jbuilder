attachment_data = attachment.push_event_data
sender = attachment.message.sender
sender_payload = if sender.is_a?(Contact)
                   sender.push_event_data(contact_inbox: attachment.message.conversation.contact_inbox)
                 elsif sender.is_a?(AgentBot)
                   sender.push_event_data(attachment.message.inbox)
                 elsif sender.present?
                   sender.push_event_data
                 end

json.id attachment_data[:id]
json.message_id attachment_data[:message_id]
json.thumb_url attachment_data[:thumb_url]
json.data_url attachment_data[:data_url]
json.file_size attachment_data[:file_size]
json.file_type attachment_data[:file_type]
json.extension attachment_data[:extension]
json.width attachment_data[:width]
json.height attachment_data[:height]
json.created_at attachment.message.created_at.to_i
json.sender sender_payload if sender_payload.present?
