# Telegram's own service account. It writes to every account (the login codes, the notices of new sign-ins and of the account
# itself) as user 777000 on the production servers. A private chat with it is not a conversation with a person, and a login
# code must never land in an inbox, so neither the live events nor the history import take it in. The webhook leaves such an
# event out before it is queued (Webhooks::TelegramPersonalController), so a login code never reaches Redis either, and the
# event service leaves it out again for the jobs already queued (TelegramPersonal::IncomingEventService).
#
# 42777 is the service account of the Telegram test servers only: on the production servers it may be a person, so it is skipped
# only when TELEGRAM_PERSONAL_TEST_SERVERS says the gateway signs in to the test servers.
#
# Only a chat the importer takes in as private (TelegramPersonal::ChatType) whose peer is one of these ids is skipped. A group is
# never skipped (in a discussion group 777000 is the sender of the posts its channel forwards there), and nothing else about a
# person's chat is looked at.
#
#   TelegramPersonal::ServiceAccount.chat?(chat_id: '777000', peer_user_id: '777000', chat_type: 'private') # => true
#   TelegramPersonal::ServiceAccount.chat?(chat_id: '42777', chat_type: 'private')                          # => false
#   TelegramPersonal::ServiceAccount.chat?(chat_id: '-100123', chat_type: 'supergroup', sender_id: '777000') # => false
#   TelegramPersonal::ServiceAccount.event?('message.created', chat_id: '777000')                           # => true
module TelegramPersonal::ServiceAccount
  USER_IDS = %w[777000].freeze
  TEST_SERVER_USER_IDS = %w[42777].freeze
  # The events that would bring a chat into the inbox: its messages (live and imported), its calls and its contact
  CHAT_EVENTS = %w[message.created message.imported message.activity contact.imported].freeze

  module_function

  # An event of the gateway that would bring the chat of a service account into the inbox
  def event?(event, data)
    CHAT_EVENTS.include?(event.to_s) && chat?(data)
  end

  def chat?(params)
    params = params.to_h.symbolize_keys
    return false unless TelegramPersonal::ChatType.private?(params)

    user_ids.include?(peer_id(params))
  end

  def user_ids
    test_servers? ? USER_IDS + TEST_SERVER_USER_IDS : USER_IDS
  end

  def test_servers?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('TELEGRAM_PERSONAL_TEST_SERVERS', nil)) == true
  end

  # The peer of a private chat the way the contact of the conversation is found (TelegramPersonal::ContactSyncService)
  def peer_id(params)
    (params[:peer_user_id].presence || params[:sender_id].presence || params[:chat_id].presence).to_s.strip
  end

  # Never the text: only that an event of a service account was left out, for which inbox
  def log_skipped(event, channel)
    Rails.logger.info(
      "[TELEGRAM PERSONAL] Skipped #{event} of a Telegram service account for inbox #{channel.inbox&.id} (channel #{channel.id})"
    )
  end
end
