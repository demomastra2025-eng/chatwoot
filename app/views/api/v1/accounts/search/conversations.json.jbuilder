json.payload do
  json.conversations do
    json.array! @result[:conversations] do |conversation|
      json.id conversation.display_id
      json.account_id conversation.account_id
      json.created_at conversation.created_at.to_i
      unless @compact_conversation_results
        message = @conversation_first_messages[conversation.id]
        if message
          json.message do
            json.partial! 'message', formats: [:json], message: message
          end
        else
          json.message nil
        end
      end
      json.contact do
        json.partial! 'contact', formats: [:json], contact: conversation.contact if conversation.try(:contact).present?
      end
      json.inbox do
        json.partial! 'inbox', formats: [:json], inbox: conversation.inbox if conversation.try(:inbox).present?
      end
      unless @compact_conversation_results
        json.agent do
          json.partial! 'agent', formats: [:json], agent: conversation.assignee if conversation.try(:assignee).present?
        end
      end

      json.additional_attributes conversation.additional_attributes
    end
  end
end
