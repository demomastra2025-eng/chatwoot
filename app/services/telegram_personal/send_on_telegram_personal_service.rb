class TelegramPersonal::SendOnTelegramPersonalService < Base::SendOnChannelService
  private

  def channel_class
    Channel::TelegramPersonal
  end

  def perform_reply
    result = TelegramPersonal::GatewayClient.new(channel: channel).send_message!(message)
    message_id = result.with_indifferent_access[:message_id]
    message_ids = Array.wrap(result.with_indifferent_access[:message_ids]).map(&:to_s).reject(&:blank?)
    if message_id.present?
      content_attributes = (message.content_attributes || {}).dup
      content_attributes[:telegram_message_ids] = message_ids if message_ids.many?
      message.update!(
        source_id: formatted_source_id(message_id),
        status: :sent,
        content_attributes: content_attributes
      )
    end
  rescue TelegramPersonal::GatewayClient::GatewayError => e
    message.update!(status: :failed, external_error: e.message)
  end

  def formatted_source_id(message_id)
    attrs = message.conversation.additional_attributes.to_h
    chat_id = attrs['chat_id'].to_s.presence || message.conversation.contact_inbox&.source_id.to_s.presence
    is_group = ActiveModel::Type::Boolean.new.cast(attrs['is_group']) == true || chat_id.to_s.start_with?('-')

    TelegramPersonal::MessageSourceId.format(message_id, chat_id: chat_id, group: is_group)
  end
end
