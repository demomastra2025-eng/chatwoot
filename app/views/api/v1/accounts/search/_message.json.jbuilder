json.partial! 'api/v1/models/message', message: message
json.communication_thread_id message.conversation.communication_thread&.display_id if Current.account.feature_enabled?('communication_threads')
