json.data do
  json.meta do
    json.mine_count @communication_threads_count[:mine_count]
    json.assigned_count @communication_threads_count[:assigned_count]
    json.unassigned_count @communication_threads_count[:unassigned_count]
    json.all_count @communication_threads_count[:all_count]
  end
  json.payload do
    json.array! @communication_threads do |communication_thread|
      json.partial! 'api/v1/accounts/communication_threads/partials/communication_thread',
                    formats: [:json],
                    communication_thread: communication_thread,
                    links: @accessible_links_by_thread_id.fetch(communication_thread.id, []),
                    channels: @channel_capabilities_by_thread_id.fetch(communication_thread.id, []),
                    last_public_message: @last_public_messages_by_thread_id[communication_thread.id]
    end
  end
end
