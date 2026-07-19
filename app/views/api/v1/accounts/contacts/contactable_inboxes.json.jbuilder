json.payload do
  json.array! @contactable_inboxes do |contactable_inbox|
    json.inbox do
      json.partial! 'api/v1/models/inbox_slim', formats: [:json], resource: contactable_inbox[:inbox]
    end
    json.source_id contactable_inbox[:source_id]
    if contactable_inbox.key?(:reply_window_open)
      json.contact_inbox_id contactable_inbox[:contact_inbox_id]
      json.active_conversation_id contactable_inbox[:active_conversation_id]
      json.reply_window_open contactable_inbox[:reply_window_open]
      json.reply_window_closes_at contactable_inbox[:reply_window_closes_at]&.iso8601
      json.allowed_content_kinds contactable_inbox[:allowed_content_kinds]
    end
  end
end
