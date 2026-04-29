class Weixin::SendOnWeixinService < Base::SendOnChannelService
  private

  def channel_class
    Channel::Weixin
  end

  def perform_reply
    result = Weixin::GatewayClient.new(channel: channel).send_message!(message)
    message_id = result.with_indifferent_access[:message_id]
    return if message_id.blank?

    message.update!(
      source_id: message_id.to_s,
      status: :sent
    )
  rescue Weixin::GatewayClient::GatewayError => e
    message.update!(status: :failed, external_error: e.message)
  end
end
