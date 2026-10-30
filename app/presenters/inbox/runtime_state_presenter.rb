# The runtime snapshot of a personal channel as the inbox API shows it (api/v1/models/_inbox), which every member of the inbox
# reads. The ids of the owner's dialogs (the checkpoint of a Telegram history import) and of the deduplicated Weixin messages are
# never shown, nor is a credential of the Telegram login (the session string, the hash of a pending login code); the QR login
# link and the ignored Telegram chats only to an administrator, who runs the login and sets them. The state of the connection,
# of the login and of the imports stays for everyone: the sidebar and the alerts of the agents read it.
#
# The diagnostics of the Telegram gateway, which an administrator reads, carry its own snapshot of the channel: it goes through
# the same rules (.telegram_personal_diagnostics).
#
#   Inbox::RuntimeStatePresenter.for(inbox.channel, administrator: false)
#   # => { 'history_sync_state' => 'running', 'history_sync_checkpoint' => { 'next_dialog_index' => 3, ... }, 'sync_groups' => false }
module Inbox::RuntimeStatePresenter
  TELEGRAM_SECRET_KEYS = %w[string_session pending_phone_code_hash api_hash webhook_secret].freeze
  TELEGRAM_HIDDEN_RUNTIME_KEYS = %w[history_sync_last_completed_dialog_id].freeze
  TELEGRAM_HIDDEN_CHECKPOINT_KEYS = %w[dialog_user_ids failed_dialog_ids last_completed_dialog_id dialog_cursors].freeze
  TELEGRAM_ADMIN_KEYS = %w[qr_login_url ignored_chat_ids].freeze
  WEIXIN_HIDDEN_KEYS = %w[message_dedup].freeze
  WEIXIN_ADMIN_KEYS = %w[qr_login_url].freeze

  module_function

  def for(channel, administrator:)
    case channel
    when Channel::TelegramPersonal then telegram_personal(channel, administrator)
    when Channel::Weixin then weixin(channel, administrator)
    end
  end

  def telegram_personal(channel, administrator)
    telegram_personal_state(channel.runtime_state_payload, administrator)
  end

  # A Telegram runtime snapshot: the one stored on the channel or the one the gateway reports
  def telegram_personal_state(state, administrator)
    payload = state.to_h.deep_stringify_keys.except(*TELEGRAM_SECRET_KEYS, *TELEGRAM_HIDDEN_RUNTIME_KEYS)
    checkpoint = payload['history_sync_checkpoint']
    payload['history_sync_checkpoint'] = checkpoint.except(*TELEGRAM_HIDDEN_CHECKPOINT_KEYS) if checkpoint.is_a?(Hash)
    administrator ? payload : payload.except(*TELEGRAM_ADMIN_KEYS)
  end

  # The diagnostics of the gateway (TelegramPersonal::GatewayClient#diagnostics) as an administrator reads them: its snapshot of the
  # channel ('channel') without the session string and the login code hash, its runtime state as the inbox API shows it.
  #
  #   telegram_personal_diagnostics('connected' => true, 'channel' => { 'string_session' => '1BV...', 'runtime_state' => { ... } })
  #   # => { 'connected' => true, 'channel' => { 'runtime_state' => { ... } } }
  def telegram_personal_diagnostics(diagnostics)
    result = diagnostics.to_h.deep_stringify_keys.except(*TELEGRAM_SECRET_KEYS, *TELEGRAM_HIDDEN_RUNTIME_KEYS)
    channel = result['channel']
    return result unless channel.is_a?(Hash)

    channel = channel.except(*TELEGRAM_SECRET_KEYS, *TELEGRAM_HIDDEN_RUNTIME_KEYS)
    channel['runtime_state'] = telegram_personal_state(channel['runtime_state'], true) if channel['runtime_state'].is_a?(Hash)
    result.merge('channel' => channel)
  end

  def weixin(channel, administrator)
    payload = channel.runtime_state.to_h.except(*WEIXIN_HIDDEN_KEYS)
    administrator ? payload : payload.except(*WEIXIN_ADMIN_KEYS)
  end
end
