class TelegramPersonal::DeleteMessagesService
  pattr_initialize [:inbox!, :params!]

  def perform
    message_ids.each do |message_id|
      message = find_message(message_id)
      next if message.blank?

      ActiveRecord::Base.transaction do
        message.update!(
          content: I18n.t('conversations.messages.deleted'),
          content_type: :text,
          content_attributes: (message.content_attributes || {}).merge(deleted: true)
        )
        message.attachments.destroy_all
      end
    end
  end

  private

  def message_ids
    Array.wrap(params[:message_ids]).map(&:to_s).reject(&:blank?).uniq
  end

  def find_message(message_id)
    inbox.messages.find_by(source_id: message_id) ||
      inbox.messages.find_each.find do |message|
        Array.wrap(message.content_attributes&.dig('telegram_message_ids')).map(&:to_s).include?(message_id)
      end
  end
end
