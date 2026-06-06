json.meta do
  json.contact do
    json.partial! 'api/v1/models/contact', formats: [:json], resource: @communication_thread.contact
  end
end

json.payload do
  json.array! @channel_capabilities_by_thread_id.fetch(@communication_thread.id, []) do |channel|
    json.partial! 'api/v1/accounts/communication_threads/partials/channel', formats: [:json], channel: channel
  end
end
