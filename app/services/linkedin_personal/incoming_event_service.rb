class LinkedinPersonal::IncomingEventService
  pattr_initialize [:channel!, :payload!]

  def perform
    case payload[:event].to_s
    when 'runtime.updated'
      process_runtime_update
    when 'contact.imported'
      LinkedinPersonal::ContactSyncService.new(inbox: channel.inbox, params: event_data).perform
    when 'message.created', 'message.imported'
      LinkedinPersonal::IncomingMessageService.new(inbox: channel.inbox, params: event_data).perform
    end

    channel.update_column(:last_synced_at, Time.current)
  end

  private

  def event_data
    payload.dig(:linkedin_personal, :data).to_h.deep_symbolize_keys
  end

  def process_runtime_update
    runtime = event_data
    channel.apply_runtime_update!(
      connection_state: runtime[:connection_state] || channel.connection_state,
      lifecycle_state: runtime[:lifecycle_state] || channel.lifecycle_state,
      last_error: runtime[:last_error],
      runtime_state: runtime.fetch(:runtime_state, {}).deep_stringify_keys,
      last_synced_at: Time.current
    )
  end
end
