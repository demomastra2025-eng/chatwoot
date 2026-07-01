json.partial! 'api/v1/accounts/communication_threads/partials/communication_thread',
              formats: [:json],
              communication_thread: @communication_thread,
              links: @accessible_links_by_thread_id.fetch(@communication_thread.id, []),
              channels: @channel_capabilities_by_thread_id.fetch(@communication_thread.id, []),
              last_public_message: @last_public_messages_by_thread_id[@communication_thread.id],
              last_non_activity_message: @last_non_activity_messages_by_thread_id[@communication_thread.id],
              crm_deal_stages_by_communication_thread_id: @crm_deal_stages_by_communication_thread_id,
              scheduling_appointment_statuses_by_communication_thread_id: @scheduling_appointment_statuses_by_communication_thread_id
