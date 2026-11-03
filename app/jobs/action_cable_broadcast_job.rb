class ActionCableBroadcastJob < ApplicationJob
  queue_as do
    arguments.second == 'communication_thread.updated' ? :communication_thread_realtime : :action_cable_realtime
  end
  include Events::Types

  CONVERSATION_UPDATE_EVENTS = [
    CONVERSATION_READ,
    CONVERSATION_UPDATED,
    TEAM_CHANGED,
    ASSIGNEE_CHANGED,
    CONVERSATION_STATUS_CHANGED
  ].freeze

  def perform(members, event_name, data)
    return if members.blank?

    broadcast_data = prepare_broadcast_data(event_name, data)
    payload = { event: event_name, data: broadcast_data }
    broadcast_to_members(members, event_name, broadcast_data)
    SuperAdmin::ImpersonationService.broadcast_to_active_sessions(
      account_id: broadcast_data[:account_id] || broadcast_data['account_id'],
      recipient_tokens: members,
      payload: payload
    )
  end

  private

  # Ensures that only the latest available data is sent to prevent UI issues
  # caused by out-of-order events during high-traffic periods. This prevents
  # the conversation job from processing outdated data.
  def prepare_broadcast_data(event_name, data)
    external_payload = data[:external_payload]
    return data.except(:external_payload) unless CONVERSATION_UPDATE_EVENTS.include?(event_name)

    account = Account.find(data[:account_id])
    conversation = account.conversations.find_by!(display_id: data[:id])
    event_data = external_payload ? conversation.external_push_event_data : conversation.push_event_data
    if !external_payload && data.key?(:scheduling_appointment_statuses)
      # Preserve the requested status refresh through canonical rehydration, but
      # never replay the queued snapshot if the appointment changed meanwhile.
      contexts = Scheduling::AppointmentDialogStatusContextBuilder.new(account: account).for_conversations([conversation])
      event_data[:scheduling_appointment_statuses] = contexts.fetch(conversation.id, [])
    end
    event_data.merge(account_id: data[:account_id])
  end

  def broadcast_to_members(members, event_name, broadcast_data)
    members.each do |member|
      ActionCable.server.broadcast(
        member,
        {
          event: event_name,
          data: broadcast_data
        }
      )
    end
  end
end
