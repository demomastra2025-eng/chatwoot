json.payload do
  json.array! @communication_threads do |communication_thread|
    json.id communication_thread.display_id
    json.contact_id communication_thread.contact_id
    json.status communication_thread.status
    json.timestamp communication_thread.last_activity_at.to_i
    json.last_activity_at communication_thread.last_activity_at.to_i
  end
end
