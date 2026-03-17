class WhatsappWeb::SendOnWhatsappWebService < Base::SendOnChannelService
  private

  def channel_class
    Channel::WhatsappWeb
  end

  def perform_reply
    message_id = channel.send_message(message)
    message.update!(source_id: message_id) if message_id.present?
  end
end
