class Messages::UpdateContentService
  class Error < StandardError; end

  EDITABLE_ATTACHMENT_TYPES = %w[image video].freeze

  pattr_initialize [:message!, :content!]

  def perform
    validate_message!

    sanitized_content = content.to_s.strip
    raise Error, 'Message content cannot be blank' if sanitized_content.blank?

    channel.update_message(message: message, content: sanitized_content)
    message.update!(
      content: sanitized_content,
      content_attributes: (message.content_attributes || {}).merge(edited: true)
    )

    message
  rescue StandardError => e
    raise e if e.is_a?(Error)

    raise Error, e.message
  end

  private

  delegate :conversation, :attachments, to: :message
  delegate :inbox, to: :conversation
  delegate :channel, to: :inbox

  def validate_message!
    raise Error, 'Message editing is only available for WhatsApp Web, Telegram, and Telegram Personal' unless editable_channel?
    raise Error, 'Only outgoing messages can be edited' unless message.outgoing?
    raise Error, "Private notes cannot be edited in #{channel_name}" if message.private?
    raise Error, 'Deleted messages cannot be edited' if (message.content_attributes || {}).with_indifferent_access[:deleted]
    raise Error, 'Message source_id is missing' if message.source_id.blank?
    raise Error, 'Only text and media caption messages can be edited' unless editable_payload?
  end

  def editable_channel?
    channel.is_a?(Channel::WhatsappWeb) ||
      channel.is_a?(Channel::Telegram) ||
      channel.is_a?(Channel::TelegramPersonal)
  end

  def channel_name
    return 'Telegram' if channel.is_a?(Channel::Telegram)
    return 'Telegram Personal' if channel.is_a?(Channel::TelegramPersonal)

    'WhatsApp Web'
  end

  def editable_payload?
    return true if attachments.blank?
    return false unless attachments.one?

    attachment_type = attachments.first.file_type.to_s
    EDITABLE_ATTACHMENT_TYPES.include?(attachment_type)
  end
end
