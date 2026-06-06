links = local_assigns.fetch(:links, [])
channels = local_assigns.fetch(:channels, [])
last_public_message = local_assigns[:last_public_message]

json.meta do
  json.sender do
    json.partial! 'api/v1/models/contact', formats: [:json], resource: communication_thread.contact
  end
  json.channel 'CommunicationThread'
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
json.conversation_ids links.map { |link| link.conversation.display_id }
json.channels do
  json.array! channels do |channel|
    json.partial! 'api/v1/accounts/communication_threads/partials/channel', formats: [:json], channel: channel
  end
end
json.status communication_thread.status
json.created_at communication_thread.created_at.to_i
json.updated_at communication_thread.updated_at.to_f
json.timestamp communication_thread.last_activity_at.to_i
json.last_activity_at communication_thread.last_activity_at.to_i
json.unread_count communication_thread.unread_count
json.priority communication_thread.priority
json.assignee_id communication_thread.assignee_id
json.team_id communication_thread.team_id
