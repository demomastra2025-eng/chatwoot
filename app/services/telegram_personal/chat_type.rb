# Whether an event of the Telegram gateway is about a private chat or a group. The importer (TelegramPersonal::IncomingMessageService)
# and the skip of Telegram's service account (TelegramPersonal::ServiceAccount) decide it here, so a chat the importer takes in as
# private is the chat the skip looks at.
#
# The chat_type of the gateway decides; only when it is missing does is_group tell a group from a private chat. A chat of another
# type (a broadcast channel) is neither, and is not taken in.
#
#   TelegramPersonal::ChatType.private?(chat_type: 'private')         # => true
#   TelegramPersonal::ChatType.private?(chat_type: nil)               # => true
#   TelegramPersonal::ChatType.group?(chat_type: nil, is_group: true) # => true
#   TelegramPersonal::ChatType.group?(chat_type: 'channel')           # => false
module TelegramPersonal::ChatType
  PRIVATE_TYPES = %w[private user private_chat].freeze
  GROUP_TYPES = %w[group supergroup].freeze

  module_function

  def private?(params)
    type = chat_type(params)
    type.present? ? type.in?(PRIVATE_TYPES) : !group_flag?(params)
  end

  def group?(params)
    type = chat_type(params)
    type.present? ? type.in?(GROUP_TYPES) : group_flag?(params)
  end

  def chat_type(params)
    value(params, :chat_type).to_s.strip
  end

  def group_flag?(params)
    ActiveModel::Type::Boolean.new.cast(value(params, :is_group)) == true
  end

  def value(params, key)
    params[key].nil? ? params[key.to_s] : params[key]
  end
end
