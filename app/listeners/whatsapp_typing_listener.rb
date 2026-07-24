class WhatsappTypingListener < BaseListener
  def conversation_typing_on(event)
    conversation = event.data[:conversation]
    return unless publishable?(event, conversation)

    message_id = conversation.messages.incoming.where.not(source_id: [nil, '']).reorder(created_at: :desc, id: :desc).pick(:source_id)
    return if message_id.blank?

    conversation.inbox.channel.provider_service.send_typing_indicator(message_id)
  rescue StandardError => e
    Rails.logger.warn(
      "[WHATSAPP_CLOUD] typing indicator skipped conversation_id=#{conversation&.id} error=#{e.class}: #{e.message}"
    )
  end

  private

  def publishable?(event, conversation)
    return false if event.data[:is_private]

    channel = conversation&.inbox&.channel
    channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
  end
end
