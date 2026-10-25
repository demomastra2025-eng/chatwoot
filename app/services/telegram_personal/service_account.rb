# Telegram's own service account. It writes to every account (the login codes, the notices of new sign-ins and of the account
# itself) as user 777000 on the production servers. A private chat with it is not a conversation with a person, and a login
# code must never land in an inbox, so neither the live events nor the history import take it in.
#
# 42777 is the service account of the Telegram test servers only: on the production servers it may be a person, so it is skipped
# only when TELEGRAM_PERSONAL_TEST_SERVERS says the gateway signs in to the test servers.
#
# Only a private chat whose peer is one of these ids is skipped. A group is never skipped (in a discussion group 777000
# is the sender of the posts its channel forwards there), and nothing else about a person's chat is looked at.
#
#   TelegramPersonal::ServiceAccount.chat?(chat_id: '777000', peer_user_id: '777000', chat_type: 'private') # => true
#   TelegramPersonal::ServiceAccount.chat?(chat_id: '42777', chat_type: 'private')                          # => false
#   TelegramPersonal::ServiceAccount.chat?(chat_id: '-100123', chat_type: 'supergroup', sender_id: '777000') # => false
module TelegramPersonal::ServiceAccount
  USER_IDS = %w[777000].freeze
  TEST_SERVER_USER_IDS = %w[42777].freeze
  GROUP_CHAT_TYPES = %w[group supergroup channel].freeze

  module_function

  def chat?(params)
    params = params.to_h.symbolize_keys
    return false if group_chat?(params)

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

  def group_chat?(params)
    params[:chat_type].to_s.in?(GROUP_CHAT_TYPES) || ActiveModel::Type::Boolean.new.cast(params[:is_group]) == true
  end
end
