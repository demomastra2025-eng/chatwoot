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
    candidates = TelegramPersonal::MessageSourceId.candidates(message_id, chat_id: target_chat_id)
    raw_id = TelegramPersonal::MessageSourceId.provider_id(message_id)

    content_attrs = Message.attributes_object_sql('content_attributes', 'messages')

    scope.where(source_id: candidates).first ||
      scope.where(
        "jsonb_typeof(#{content_attrs} -> 'telegram_message_ids') = 'array' " \
        "AND (#{content_attrs} -> 'telegram_message_ids') @> CAST(? AS jsonb)",
        [raw_id].to_json
      ).first
  end

  def scoped_messages
    return inbox.messages if target_chat_id.blank?

    contact_inbox = inbox.contact_inboxes.find_by(source_id: target_chat_id)
    return inbox.messages.none if contact_inbox.blank?

    inbox.messages.joins(:conversation).where(conversations: { contact_inbox_id: contact_inbox.id })
  end

  def target_chat_id
    (params[:chat_id] || params[:peer_user_id]).to_s.presence
  end
end
