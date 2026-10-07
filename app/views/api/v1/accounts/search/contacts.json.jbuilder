json.payload do
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
end
