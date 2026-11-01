module TelegramPersonal::MessageSourceId
  GROUP_PREFIX = 'tg_group'.freeze
  GROUP_SOURCE_ID_PATTERN = /\A#{GROUP_PREFIX}:(-?\d+):(.+)\z/

  module_function

  def format(message_id, chat_id: nil, group: false)
    raw_id = provider_id(message_id)
    return raw_id if raw_id.blank?
    return raw_id unless group && chat_id.present?

    "#{GROUP_PREFIX}:#{chat_id}:#{raw_id}"
  end

  def provider_id(source_id)
    value = source_id.to_s
    return '' if value.blank?

    match = GROUP_SOURCE_ID_PATTERN.match(value)
    match ? match[2] : value
  end

  def candidates(message_id, chat_id: nil)
    raw_id = provider_id(message_id)
    return [] if raw_id.blank?

    values = [message_id.to_s, raw_id]
    values << format(raw_id, chat_id: chat_id, group: true) if chat_id.present?
    values.reject(&:blank?).uniq
  end
end
