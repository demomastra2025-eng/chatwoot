json.source_id resource.source_id
json.channel_profile resource.channel_profile&.push_event_data
json.inbox do
  json.partial! 'api/v1/models/inbox_slim', formats: [:json], resource: resource.inbox
end
