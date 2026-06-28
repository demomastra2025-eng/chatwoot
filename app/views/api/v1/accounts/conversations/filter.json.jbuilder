json.meta do
  json.mine_count @conversations_count[:mine_count]
  json.assigned_count @conversations_count[:assigned_count]
  json.unassigned_count @conversations_count[:unassigned_count]
  json.all_count @conversations_count[:all_count]
  json.assignee_counts @conversations_count[:assignee_counts]
  json.unread_counts @conversations_count[:unread_counts]
end
json.payload do
  json.array! @conversations do |conversation|
    json.partial! 'api/v1/conversations/partials/conversation',
                  formats: [:json],
                  conversation: conversation,
                  crm_deal_stages_by_conversation_id: @crm_deal_stages_by_conversation_id
  end
end
