# The runtime snapshot of a personal channel as the inbox API shows it (api/v1/models/_inbox), which every member of the inbox
# reads. The ids of the owner's dialogs (the checkpoint of a Telegram history import) and of the deduplicated Weixin messages are
# never shown; the QR login link and the ignored Telegram chats only to an administrator, who runs the login and sets them.
# The state of the connection, of the login and of the imports stays for everyone: the sidebar and the alerts of the agents read it.
#
#   Inbox::RuntimeStatePresenter.for(inbox.channel, administrator: false)
#   # => { 'history_sync_state' => 'running', 'history_sync_checkpoint' => { 'next_dialog_index' => 3, ... }, 'sync_groups' => false }
module Inbox::RuntimeStatePresenter
  TELEGRAM_HIDDEN_CHECKPOINT_KEYS = %w[dialog_user_ids last_completed_dialog_id].freeze
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
    payload = channel.runtime_state_payload
    checkpoint = payload['history_sync_checkpoint']
    payload['history_sync_checkpoint'] = checkpoint.except(*TELEGRAM_HIDDEN_CHECKPOINT_KEYS) if checkpoint.is_a?(Hash)
    administrator ? payload : payload.except(*TELEGRAM_ADMIN_KEYS)
  end

  def weixin(channel, administrator)
    payload = channel.runtime_state.to_h.except(*WEIXIN_HIDDEN_KEYS)
    administrator ? payload : payload.except(*WEIXIN_ADMIN_KEYS)
  end
end
