json.data do
  json.meta do
    json.merge! @search_meta
  end
  json.payload do
    json.array! @conversations do |conversation|
      json.partial! 'api/v1/conversations/partials/conversation',
                    formats: [:json],
                    conversation: conversation,
                    crm_deal_stages_by_conversation_id: @crm_deal_stages_by_conversation_id,
                    scheduling_appointment_statuses_by_conversation_id: @scheduling_appointment_statuses_by_conversation_id
    end
  end
end
