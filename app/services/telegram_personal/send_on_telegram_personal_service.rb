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
        source_id: message_id.to_s,
        status: :sent,
        content_attributes: content_attributes
      )
    end
  rescue TelegramPersonal::GatewayClient::GatewayError => e
    message.update!(status: :failed, external_error: e.message)
  end
end
