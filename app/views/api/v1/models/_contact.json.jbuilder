json.additional_attributes(
  if defined?(excluded_additional_attribute_keys) && excluded_additional_attribute_keys.present?
    resource.additional_attributes.to_h.except(*Array(excluded_additional_attribute_keys).map(&:to_s))
  else
    resource.additional_attributes
  end
)
json.availability_status resource.availability_status
json.email resource.email
json.id resource.id
json.name resource.name
json.owner_id resource.owner_id
if resource.owner.present?
  json.owner do
    json.partial! 'api/v1/models/agent', formats: [:json], resource: resource.owner
  end
else
  json.owner nil
end
json.phone_number resource.phone_number
json.blocked resource.blocked
json.identifier resource.identifier
json.thumbnail resource.resolved_avatar_url
json.contact_avatar_url resource.contact_avatar_url
json.custom_attributes resource.custom_attributes
json.primary_name_source resource.resolved_primary_name_source
json.primary_avatar_source resource.resolved_primary_avatar_source
json.last_activity_at resource.last_activity_at.to_i if resource[:last_activity_at].present?
json.created_at resource.created_at.to_i if resource[:created_at].present?
# we only want to output contact inbox when its /contacts endpoints
if defined?(with_contact_inboxes) && with_contact_inboxes.present?
  json.channel_profiles do
    json.array! resource.contact_channel_profiles do |channel_profile|
      json.merge! channel_profile.push_event_data
    end
  end
  json.contact_inboxes do
    json.array! resource.contact_inboxes do |contact_inbox|
      json.partial! 'api/v1/models/contact_inbox', formats: [:json], resource: contact_inbox
    end
  end
end
