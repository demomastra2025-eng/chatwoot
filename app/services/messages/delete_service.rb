class Messages::DeleteService
  class Error < StandardError; end

  pattr_initialize [:message!]

  def perform
    provider_delete_if_supported!
    soft_delete_message!
    message
  rescue StandardError => e
    raise e if e.is_a?(Error)

    raise Error, e.message
  end

  private

  delegate :conversation, to: :message
  delegate :inbox, to: :conversation

  def provider_delete_if_supported!
    return unless channel.is_a?(Channel::TelegramPersonal)

    validate_telegram_personal_message!
    channel.delete_message(message: message)
  end

  def soft_delete_message!
    ActiveRecord::Base.transaction do
      if channel.is_a?(Channel::TelegramPersonal)
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

  def validate_telegram_personal_message!
    raise Error, 'Only outgoing Telegram Personal messages can be deleted' unless message.outgoing?
    raise Error, 'Private notes cannot be deleted in Telegram Personal' if message.private?
    raise Error, 'Deleted messages cannot be deleted again' if (message.content_attributes || {}).with_indifferent_access[:deleted]
    raise Error, 'Message source_id is missing' if message.source_id.blank?
  end

  def channel
    inbox.channel
  end
end
