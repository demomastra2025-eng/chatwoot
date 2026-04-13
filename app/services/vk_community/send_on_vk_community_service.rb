class VkCommunity::SendOnVkCommunityService < Base::SendOnChannelService
  private

  def channel_class
    Channel::VkCommunity
  end

  def perform_reply
    attachments = message.attachments.map { |attachment| channel.api_client.upload_attachment(attachment) }
    message_id = channel.api_client.send_message(
      peer_id: conversation.additional_attributes['peer_id'] || contact_inbox.source_id,
      text: message.outgoing_content,
      reply_to_message_id: message.content_attributes['in_reply_to_external_id'],
      attachments: attachments
    )
    message.update!(source_id: message_id.to_s, status: :sent)
  rescue VkCommunity::ApiClient::ApiError => e
    message.update!(status: :failed, external_error: e.message)
  end
end
