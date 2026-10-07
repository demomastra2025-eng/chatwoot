json.payload do
  json.conversations do
    json.array! @result[:conversations] do |conversation|
      json.partial! 'conversation_search_result', formats: [:json], conversation: conversation
    end
  end
  json.contacts do
    json.array! @result[:contacts] do |contact|
      json.partial! 'contact', formats: [:json], contact: contact
      conversation = @contact_latest_conversations[contact.id]
      if conversation
        json.latest_conversation do
          json.id conversation.display_id
          json.inbox_id conversation.inbox_id
          json.communication_thread_id conversation.communication_thread&.display_id if Current.account.feature_enabled?('communication_threads')
        end
      end
    end
  end
  json.messages do
    json.array! @result[:messages] do |message|
      json.partial! 'message', formats: [:json], message: message
    end
  end
  json.articles do
    json.array! @result[:articles] do |article|
      json.partial! 'article', formats: [:json], article: article
    end
  end
end
