class TelegramPersonal::IncomingEventService
  # The events that would bring a chat into the inbox: its messages (live and imported), its calls and its contact
  CHAT_EVENTS = %w[message.created message.imported message.activity contact.imported].freeze
  EVENT_SERVICES = {
    'contact.imported' => 'TelegramPersonal::ContactSyncService',
    'message.created' => 'TelegramPersonal::IncomingMessageService',
    'message.imported' => 'TelegramPersonal::IncomingMessageService',
    'message.activity' => 'TelegramPersonal::CreateActivityMessageService',
    'message.updated' => 'TelegramPersonal::UpdateMessageService',
    'message.read' => 'TelegramPersonal::UpdateMessageReadStatusService',
    'message.deleted' => 'TelegramPersonal::DeleteMessagesService'
  }.freeze

  pattr_initialize [:channel!, :payload!]

  def perform
    if service_account_chat?
      log_skipped_service_account_event
    else
      process_event
    end

    channel.update_column(:last_synced_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  private

  def process_event
    return process_runtime_update if event == 'runtime.updated'

    EVENT_SERVICES[event]&.constantize&.new(inbox: channel.inbox, params: event_data)&.perform
  end

  def event
    payload[:event].to_s
  end

  def event_data
    @event_data ||= payload.dig(:telegram_personal, :data).to_h.deep_symbolize_keys
  end

  # The login codes and notices of Telegram itself (TelegramPersonal::ServiceAccount) are not taken in
  def service_account_chat?
    CHAT_EVENTS.include?(event) && TelegramPersonal::ServiceAccount.chat?(event_data)
  end

  # Never the text: only that an event of a service account was left out, for which inbox
  def log_skipped_service_account_event
    Rails.logger.info(
      "[TELEGRAM PERSONAL] Skipped #{event} of a Telegram service account for inbox #{channel.inbox&.id} (channel #{channel.id})"
    )
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
