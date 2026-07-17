links = local_assigns.fetch(:links, [])
channels = local_assigns.fetch(:channels, [])
last_public_message = local_assigns[:last_public_message]
last_non_activity_message = local_assigns[:last_non_activity_message]
linked_conversations = links.filter_map(&:conversation)
agent_last_seen_values = linked_conversations.map(&:agent_last_seen_at)
assignee_last_seen_values = linked_conversations.map(&:assignee_last_seen_at)
thread_agent_last_seen_at =
  agent_last_seen_values.min.to_i if agent_last_seen_values.present? && agent_last_seen_values.all?(&:present?)
thread_assignee_last_seen_at =
  assignee_last_seen_values.min.to_i if assignee_last_seen_values.present? && assignee_last_seen_values.all?(&:present?)
thread_pinned = linked_conversations.any? do |conversation|
  ActiveModel::Type::Boolean.new.cast(conversation.custom_attributes&.dig('pinned'))
end
meta_ad_referral = (@meta_ad_referrals_by_communication_thread_id || {})[communication_thread.id]
directional_message_timestamps = (@last_message_activity_by_thread_id || {}).fetch(communication_thread.id, {})

json.meta do
  json.sender do
    json.partial! 'api/v1/models/contact',
                  formats: [:json],
                  resource: communication_thread.contact,
                  excluded_additional_attribute_keys: ['last_meta_ad_referral']
  end
  json.channel 'CommunicationThread'
  json.meta_ad_referral meta_ad_referral.summary if meta_ad_referral.present?
  if communication_thread.assignee.present?
    json.assignee do
      json.partial! 'api/v1/models/agent', formats: [:json], resource: communication_thread.assignee
    end
    json.assignee_type 'User'
  end
  if communication_thread.team.present?
    json.team do
      json.partial! 'api/v1/models/team', formats: [:json], resource: communication_thread.team
    end
  end
end

json.id communication_thread.display_id
json.account_id communication_thread.account_id
json.contact_id communication_thread.contact_id
json.inbox_id nil
json.messages(last_public_message.present? ? [last_public_message.push_event_data] : [])
json.last_non_activity_message last_non_activity_message&.push_event_data
json.conversation_ids(links.map { |link| link.conversation.display_id })
json.channels do
  json.array! channels do |channel|
    json.partial! 'api/v1/accounts/communication_threads/partials/channel', formats: [:json], channel: channel
  end
end
json.labels Labels::UnifiedAssignmentService.union_for(contact: communication_thread.contact, conversations: linked_conversations)
json.custom_attributes(thread_pinned ? { pinned: true } : {})
json.crm_deal_stages((local_assigns[:crm_deal_stages_by_communication_thread_id] || {}).fetch(communication_thread.id, []))
json.scheduling_appointment_statuses(
  (local_assigns[:scheduling_appointment_statuses_by_communication_thread_id] || {}).fetch(communication_thread.id, [])
)
json.status communication_thread.status
json.created_at communication_thread.created_at.to_i
json.updated_at communication_thread.updated_at.to_f
json.timestamp communication_thread.last_activity_at.to_i
json.last_activity_at communication_thread.last_activity_at.to_i
json.waiting_since communication_thread[:thread_waiting_since_sort_at]&.to_i if communication_thread.has_attribute?(:thread_waiting_since_sort_at)
json.last_incoming_message_at directional_message_timestamps[:incoming]&.to_i
json.last_outgoing_message_at directional_message_timestamps[:outgoing]&.to_i
json.agent_last_seen_at thread_agent_last_seen_at
json.assignee_last_seen_at thread_assignee_last_seen_at
json.unread_count communication_thread.unread_count
json.priority communication_thread.priority
json.assignee_id communication_thread.assignee_id
json.team_id communication_thread.team_id
