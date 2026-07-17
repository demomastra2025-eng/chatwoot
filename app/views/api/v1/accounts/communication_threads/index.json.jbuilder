json.data do
  json.meta do
    if @communication_threads_count.present?
      json.mine_count @communication_threads_count[:mine_count]
      json.assigned_count @communication_threads_count[:assigned_count]
      json.unassigned_count @communication_threads_count[:unassigned_count]
      json.all_count @communication_threads_count[:all_count]
      json.mine_unread_count @communication_threads_count[:mine_unread_count]
      json.assigned_unread_count @communication_threads_count[:assigned_unread_count]
      json.unassigned_unread_count @communication_threads_count[:unassigned_unread_count]
      json.all_unread_count @communication_threads_count[:all_unread_count]
      json.assignee_counts @communication_threads_count[:assignee_counts]
      json.unread_counts @communication_threads_count[:unread_counts]
    end
  end
  json.payload do
    json.array! @communication_threads do |communication_thread|
      json.partial! 'api/v1/accounts/communication_threads/partials/communication_thread',
                    formats: [:json],
                    communication_thread: communication_thread,
                    links: @accessible_links_by_thread_id.fetch(communication_thread.id, []),
                    channels: @channel_capabilities_by_thread_id.fetch(communication_thread.id, []),
                    last_public_message: @last_public_messages_by_thread_id[communication_thread.id],
                    last_non_activity_message: @last_non_activity_messages_by_thread_id[communication_thread.id],
                    crm_deal_stages_by_communication_thread_id: @crm_deal_stages_by_communication_thread_id,
                    scheduling_appointment_statuses_by_communication_thread_id: @scheduling_appointment_statuses_by_communication_thread_id
    end
  end
end
