json.communication_thread_id nil
json.contact do
  json.partial! 'api/v1/models/contact', formats: [:json], resource: @contact
end
json.channels do
  json.array! @channels do |channel|
    json.partial! 'api/v1/accounts/communication_threads/partials/channel', formats: [:json], channel: channel
  end
end
json.shared_phone_holder(@shared_phone_holder && { id: @shared_phone_holder.id, name: @shared_phone_holder.display_full_name })
json.blocked @contact.blocked
