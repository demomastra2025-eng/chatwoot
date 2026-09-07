# TODO: Move this into models jbuilder
# Currently the file there is used only for search endpoint.
# Everywhere else we use conversation builder in partials folder

json.meta do
  json.sender do
    json.partial! 'api/v1/models/contact', formats: [:json], resource: conversation.contact
  end
  json.channel conversation.inbox.try(:channel_type)
  if conversation.assigned_entity&.account
    json.assignee do
      json.partial! 'api/v1/models/agent', formats: [:json], resource: conversation.assigned_entity
    end
    json.assignee_type 'User'
  end
  if conversation.team.present?
    json.team do
      json.partial! 'api/v1/models/team', formats: [:json], resource: conversation.team
    end
  end
  json.current_user_participant(
    conversation.conversation_participants.any? do |participant|
      participant.user_id == Current.user.id
    end
  )
  if conversation.contact_inbox.present?
    json.contact_inbox do
      json.partial! 'api/v1/models/contact_inbox',
                    formats: [:json],
                    resource: conversation.contact_inbox
    end
  end
  json.hmac_verified conversation.contact_inbox&.hmac_verified
end

json.id conversation.display_id
conversation_public_messages = conversation.messages.where(account_id: conversation.account_id, private: false)
directional_message_timestamps = (@last_message_activity_by_conversation_id || {}).fetch(conversation.id, {})
list_preloader = @conversation_list_preloader

if list_preloader
  last_message = list_preloader.last_message(conversation)
  json.messages(last_message ? [list_preloader.message_payload(last_message)] : [])
elsif conversation_public_messages.last.blank?
  json.messages []
else
  json.messages [
    conversation_public_messages.includes([{ attachments: [{ file_attachment: [:blob] }] }]).last.try(:push_event_data)
  ]
end

json.account_id conversation.account_id
json.campaign_id conversation.campaign_id
if conversation.campaign.present?
  json.campaign do
    json.id conversation.campaign.display_id
    json.title conversation.campaign.title
    json.campaign_type conversation.campaign.campaign_type
  end
end
json.uuid conversation.uuid
json.additional_attributes conversation.additional_attributes
json.agent_last_seen_at conversation.agent_last_seen_at.to_i
json.assignee_last_seen_at conversation.assignee_last_seen_at.to_i
json.can_reply(list_preloader ? list_preloader.can_reply?(conversation) : conversation.can_reply?)
json.contact_last_seen_at conversation.contact_last_seen_at.to_i
json.custom_attributes conversation.custom_attributes
json.inbox_id conversation.inbox_id
json.labels(list_preloader ? list_preloader.labels(conversation) : Labels::UnifiedAssignmentService.union_for(contact: conversation.contact, conversations: [conversation]))
json.crm_deal_stages((local_assigns[:crm_deal_stages_by_conversation_id] || {}).fetch(conversation.id, []))
json.scheduling_appointment_statuses((local_assigns[:scheduling_appointment_statuses_by_conversation_id] || {}).fetch(conversation.id, []))
json.muted conversation.muted?
json.snoozed_until conversation.snoozed_until
json.status conversation.status
json.created_at conversation.created_at.to_i
json.updated_at conversation.updated_at.to_f
json.timestamp conversation.last_activity_at.to_i
json.first_reply_created_at conversation.first_reply_created_at.to_i
json.unread_count(list_preloader ? list_preloader.unread_count(conversation) : conversation.unread_incoming_messages_count)
json.last_incoming_message_at directional_message_timestamps[:incoming]&.to_i
json.last_outgoing_message_at directional_message_timestamps[:outgoing]&.to_i
json.last_non_activity_message(
  if list_preloader
    list_preloader.message_payload(list_preloader.last_non_activity_message(conversation))
  else
    conversation_public_messages.non_activity_messages.first.try(:push_event_data)
  end
)
json.last_activity_at conversation.last_activity_at.to_i
json.priority conversation.priority
json.waiting_since conversation.waiting_since.to_i.to_i
json.sla_policy_id conversation.sla_policy_id
json.partial! 'enterprise/api/v1/conversations/partials/conversation', conversation: conversation if ChatwootApp.enterprise?
