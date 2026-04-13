class Telegram::MarkMessagesReadService
  pattr_initialize [:conversation!, { messages: nil }]

  def perform
    return false unless channel.is_a?(Channel::Telegram)
    return false if business_connection_id.blank?

    provider_messages.each do |message|
      channel.mark_message_read(message: message)
    end

    provider_messages.any?
  rescue StandardError => e
    Rails.logger.warn(
      "[TELEGRAM] Failed to mark messages read for conversation=#{conversation.id} channel=#{channel.id}: #{e.class}: #{e.message}"
    )
    false
  end

  private

  delegate :inbox, to: :conversation

  def channel
    inbox.channel
  end

  def business_connection_id
    conversation.additional_attributes['business_connection_id'].presence
  end

  def provider_messages
    @provider_messages ||= begin
      scope = Array.wrap(messages).presence || conversation.unread_messages.where(account_id: conversation.account_id).incoming.to_a
      scope.select { |message| message.source_id.to_s.match?(/\A\d+\z/) }
    end
  end
end
