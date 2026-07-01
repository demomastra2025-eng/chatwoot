json.partial! 'api/v1/conversations/partials/conversation',
              formats: [:json],
              conversation: @conversation,
              crm_deal_stages_by_conversation_id: @crm_deal_stages_by_conversation_id,
              scheduling_appointment_statuses_by_conversation_id: @scheduling_appointment_statuses_by_conversation_id
