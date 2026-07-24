class Whatsapp::MarkMessagesReadService
  PROVIDER_READ_WINDOW = 30.days

  pattr_initialize [:conversation!, { messages: nil }]

  def perform
    return false unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'

    latest_message = latest_unread_message
    return false if latest_message.blank?

    channel.provider_service.mark_message_read(latest_message.source_id)
  rescue StandardError => e
    error_message = Meta::CredentialDataSanitizer.sanitize(
      e.message.to_s,
      secrets: Meta::CredentialDataSanitizer.channel_secrets(channel)
    )
    Rails.logger.warn(
      "[WHATSAPP_CLOUD] Failed to mark messages read for conversation=#{conversation.id} channel=#{channel.id}: #{e.class}: #{error_message}"
    )
    false
  end

  private

  def channel
    conversation.inbox.channel
  end

  def unread_messages
    Array.wrap(messages).presence || unread_messages_scope.to_a
  end

  def unread_messages_scope
    conversation.unread_messages
                .where(account_id: conversation.account_id)
                .incoming
                .where.not(source_id: [nil, ''])
                .select(:id, :source_id, :created_at, :content_attributes)
  end

  def latest_unread_message
    unread_messages.select { |message| provider_read_receipt_eligible?(message) }.max_by do |message|
      [message.created_at || Time.zone.at(0), message.id]
    end
  end

  def provider_read_receipt_eligible?(message)
    return false if message.source_id.blank? || message.created_at.blank?
    return false if message.content_attributes.to_h['whatsapp_history_import']

    message.created_at >= PROVIDER_READ_WINDOW.ago
  end
end
