class TelegramPersonal::IncomingEventService
  EVENT_SERVICES = {
    'contact.imported' => 'TelegramPersonal::ContactSyncService',
    'message.created' => 'TelegramPersonal::IncomingMessageService',
    'message.imported' => 'TelegramPersonal::IncomingMessageService',
    'message.activity' => 'TelegramPersonal::CreateActivityMessageService',
    'message.updated' => 'TelegramPersonal::UpdateMessageService',
    'message.read' => 'TelegramPersonal::UpdateMessageReadStatusService',
    'message.deleted' => 'TelegramPersonal::DeleteMessagesService'
  }.freeze

  CALL_EVENTS = %w[call.incoming call.accepted call.ended].freeze

  pattr_initialize [:channel!, :payload!]

  def perform
    # The login codes and notices of Telegram itself are not taken in (TelegramPersonal::ServiceAccount)
    if TelegramPersonal::ServiceAccount.event?(event, event_data)
      TelegramPersonal::ServiceAccount.log_skipped(event, channel)
    else
      process_event
    end

    channel.update_column(:last_synced_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  private

  def process_event
    return process_runtime_update if event == 'runtime.updated'
    return process_call_event if CALL_EVENTS.include?(event)

    EVENT_SERVICES[event]&.constantize&.new(inbox: channel.inbox, params: event_data)&.perform
  end

  def process_call_event
    return unless defined?(TelegramPersonal::IncomingCallService)

    TelegramPersonal::IncomingCallService.new(inbox: channel.inbox, event: event, params: event_data).perform
  end

  def event
    payload[:event].to_s
  end

  def event_data
    @event_data ||= payload.dig(:telegram_personal, :data).to_h.deep_symbolize_keys
  end

  def process_runtime_update
    runtime = event_data
    channel.apply_runtime_update!(
      connection_state: runtime[:connection_state] || channel.connection_state,
      lifecycle_state: runtime[:lifecycle_state] || channel.lifecycle_state,
      last_error: runtime[:last_error],
      runtime_state: runtime.fetch(:runtime_state, {}).deep_stringify_keys,
      string_session: runtime[:string_session].presence || channel.string_session,
      last_synced_at: Time.current
    )
  end
end
