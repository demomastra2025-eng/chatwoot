class Messages::DeleteService
  class Error < StandardError; end

  PROVIDER_DELETE_WINDOW = 48.hours

  pattr_initialize [:message!]

  def perform
    validate_and_delete_from_provider!
    soft_delete_message!
    message
  rescue StandardError => e
    raise e if e.is_a?(Error)

    raise Error, e.message
  end

  private

  delegate :conversation, to: :message
  delegate :inbox, to: :conversation

  def validate_and_delete_from_provider!
    raise Error, 'Deleted messages cannot be deleted again' if already_deleted?
    return if message.private?

    if channel.is_a?(Channel::TelegramPersonal)
      validate_provider_outgoing_message!('Telegram Personal')
      channel.delete_message(message: message)
    elsif channel.is_a?(Channel::Telegram)
      validate_provider_outgoing_message!('Telegram', enforce_window: true)
      channel.delete_message(message: message)
    elsif channel.is_a?(Channel::WhatsappWeb)
      validate_provider_outgoing_message!('WhatsApp Web', enforce_window: true)
      channel.delete_message(message: message)
    elsif channel.is_a?(Channel::WebWidget)
      nil
    else
      raise Error, "Message deletion is not supported for #{channel&.name || 'this channel'}"
    end
  end

  def soft_delete_message!
    ActiveRecord::Base.transaction do
      if !message.private? && channel.is_a?(Channel::TelegramPersonal)
        message.update!(
          content: I18n.t('conversations.messages.deleted'),
          content_type: :text,
          content_attributes: (message.content_attributes || {}).merge(deleted: true)
        )
      else
        message.update!(
          content: I18n.t('conversations.messages.deleted'),
          content_type: :text,
          content_attributes: { deleted: true }
        )
      end
      message.attachments.destroy_all
    end
  end

  def validate_provider_outgoing_message!(channel_label, enforce_window: false)
    raise Error, "Only outgoing #{channel_label} messages can be deleted" unless message.outgoing?
    raise Error, 'Message source_id is missing' if message.source_id.blank?

    return unless enforce_window && message.respond_to?(:created_at) && message.created_at.present?

    raise Error, "#{channel_label} message deletion window has expired" if message.created_at < PROVIDER_DELETE_WINDOW.ago
  end

  def already_deleted?
    (message.content_attributes || {}).with_indifferent_access[:deleted].present?
  end

  def channel
    inbox.channel
  end
end
