class TelegramPersonal::UpdateMessageService
  class InvalidEditMetadataError < StandardError; end

  pattr_initialize [:inbox!, :params!]

  def self.provider_edit_time!(params)
    return unless params.key?(:text) || params.key?(:caption)

    unless params.key?(:message_edited_at) && [true, false].include?(params[:message_edit_hidden])
      raise InvalidEditMetadataError,
            'Telegram Personal full updates require provider edit metadata; upgrade and drain the gateway before app cutover'
    end

    Time.iso8601(params[:message_edited_at]) unless params[:message_edited_at].nil?
  rescue ArgumentError, TypeError
    raise InvalidEditMetadataError, 'Telegram Personal message_edited_at must be an ISO8601 timestamp or null'
  end

  def perform
    edited_at = self.class.provider_edit_time!(params)
    message = find_message
    return if message.blank?

    message.with_lock { apply_update!(message, edited_at) }
  end

  private

  def apply_update!(message, edited_at)
    content = message.content
    attributes = updated_content_attributes
    if new_provider_edit?(message, edited_at)
      content = params[:text].presence || params[:caption] || ''
      attributes[:edited] = !params[:message_edit_hidden]
      attributes[:telegram_message_edited_at] = edited_at.iso8601
    end
    message.update!(content: content, content_attributes: (message.content_attributes || {}).merge(attributes))
  end

  def new_provider_edit?(message, edited_at)
    return false if edited_at.nil?

    previous = message.content_attributes[:telegram_message_edited_at]
    previous.nil? || edited_at >= Time.iso8601(previous)
  rescue ArgumentError, TypeError
    raise InvalidEditMetadataError, 'Telegram Personal stored edit watermark is not an ISO8601 timestamp'
  end

  def updated_content_attributes
    {}.tap do |attrs|
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
