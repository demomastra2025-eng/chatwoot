class TelegramPersonal::UpdateMessageService
  pattr_initialize [:inbox!, :params!]

  def perform
    message = find_message
    return if message.blank?

    message.update!(
      content: params[:text].presence || params[:caption].presence || message.content,
      content_attributes: (message.content_attributes || {}).merge(updated_content_attributes)
    )
  end

  private

  def updated_content_attributes
    {}.tap do |attrs|
      attrs[:edited] = true if params[:text].present? || params[:caption].present?
      attrs[:telegram_reactions] = params[:reactions].to_h if params.key?(:reactions)
      attrs[:telegram_forwarded_from] = params[:forwarded_from].to_h if params[:forwarded_from].present?
    end
  end

  def find_message
    message_id = params[:message_id].to_s
    return if message_id.blank?

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
