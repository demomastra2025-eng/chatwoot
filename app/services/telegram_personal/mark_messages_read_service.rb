class TelegramPersonal::MarkMessagesReadService
  pattr_initialize [:conversation!, { messages: nil }]

  def perform
    return false unless channel.is_a?(Channel::TelegramPersonal)

    max_id = provider_max_id
    return false if max_id.blank?

    TelegramPersonal::GatewayClient.new(channel: channel).mark_read!(
      recipient_id: contact_inbox&.source_id.to_s,
      chat_id: conversation.additional_attributes['chat_id'].presence || contact_inbox&.source_id.to_s,
      max_id: max_id
    )
    true
  rescue TelegramPersonal::GatewayClient::GatewayError => e
    Rails.logger.warn(
      "[TELEGRAM PERSONAL] Failed to mark messages read for conversation=#{conversation.id} channel=#{channel.id}: #{e.class}: #{e.message}"
    )
    false
  end

  private

  delegate :inbox, :contact_inbox, to: :conversation

  def channel
    inbox.channel
  end

  def unread_messages
    Array.wrap(messages).presence ||
      conversation.unread_messages.where(account_id: conversation.account_id).incoming.to_a
  end

  def provider_max_id
    telegram_message_ids.filter_map do |message_id|
      value = message_id.to_s
      next unless value.match?(/\A\d+\z/)

      value.to_i
    end.max&.to_s
  end

  def telegram_message_ids
    unread_messages.flat_map do |message|
      ids = Array.wrap(message.content_attributes.to_h['telegram_message_ids']).presence || [message.source_id]
      ids.compact
    end
  end
end
