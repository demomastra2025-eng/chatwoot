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
    scope = scoped_messages
    scope.find_by(source_id: message_id) ||
      scope.find_each.find do |message|
        Array.wrap(message.content_attributes&.dig('telegram_message_ids')).map(&:to_s).include?(message_id)
      end
  end

  def scoped_messages
    chat_id = (params[:chat_id] || params[:peer_user_id]).to_s.presence
    return inbox.messages if chat_id.blank?

    contact_inbox = inbox.contact_inboxes.find_by(source_id: chat_id)
    return inbox.messages.none if contact_inbox.blank?

    inbox.messages.joins(:conversation).where(conversations: { contact_inbox_id: contact_inbox.id })
  end
end
