class Tiktok::SendOnTiktokService < Base::SendOnChannelService
  UnsupportedMessage = Class.new(StandardError)
  SUPPORTED_IMAGE_CONTENT_TYPES = %w[image/jpeg image/png].freeze
  MAX_IMAGE_SIZE = 3.megabytes

  private

  def channel_class
    Channel::Tiktok
  end

  def perform_reply
    validate_message_support!
    message_id = send_message
    return :outcome_unknown if message_id.blank?

    if captain_dispatching?
      # Do not emit a message update (and reminder post-delivery action) before
      # the Captain fence has committed its submitted state and receipt.
      message.update_columns(source_id: message_id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    else
      message.update!(source_id: message_id)
      Messages::StatusUpdateService.new(message, 'delivered').perform
    end
    :delivered
  rescue StandardError => e
    Rails.logger.error "Failed to send Tiktok message: #{e.message}"
    # A provider id means the send succeeded; a later DB/status error must not
    # turn an accepted message into a rejected one.
    raise if message_id.present?

    return captain_error_result(e) if captain_dispatching?

    Messages::StatusUpdateService.new(message, 'failed', e.message).perform
    :provider_failed
  end

  def captain_dispatching?
    message.sender_type == 'Captain::Assistant' && message.additional_attributes.to_h['captain_delivery_state'] == 'dispatching'
  end

  def captain_error_result(error)
    return [:provider_failed, error.message] if error.is_a?(UnsupportedMessage) || error.is_a?(Tiktok::Client::ProviderRejection)

    # A transport error or dispatch deadline may follow an accepted POST.
    :outcome_unknown
  end

  def validate_message_support!
    return unless message.attachments.any?
    raise UnsupportedMessage, 'Sending attachments with text is not supported on TikTok.' if message.outgoing_content.present?
    raise UnsupportedMessage, 'Sending multiple attachments in a single TikTok message is not supported.' unless message.attachments.one?

    validate_attachment_support!(message.attachments.first)
  end

  def validate_attachment_support!(attachment)
    raise UnsupportedMessage, 'Sending image attachments is not supported for this TikTok conversation.' unless image_send_capable?
    raise UnsupportedMessage, 'Only image attachments are supported on TikTok.' unless attachment.image?
    raise UnsupportedMessage, 'TikTok supports only JPG and PNG images.' unless SUPPORTED_IMAGE_CONTENT_TYPES.include?(attachment.file.content_type)
    raise UnsupportedMessage, 'TikTok image attachments must be smaller than 3 MB.' if attachment.file.byte_size > MAX_IMAGE_SIZE
  end

  def image_send_capable?
    message.conversation.additional_attributes.dig('tiktok_capabilities', 'image_send') != false
  end

  def send_message
    tt_conversation_id = message.conversation[:additional_attributes]['conversation_id']
    tt_referenced_message_id = message.content_attributes['in_reply_to_external_id']

    if message.attachments.any?
      tiktok_client.send_media_message(tt_conversation_id, message.attachments.first)
    else
      tiktok_client.send_text_message(tt_conversation_id, message.outgoing_content, referenced_message_id: tt_referenced_message_id)
    end
  end

  def tiktok_client
    @tiktok_client ||= Tiktok::Client.new(business_id: channel.business_id, access_token: channel.validated_access_token)
  end

  def inbox
    @inbox ||= message.inbox
  end

  def channel
    @channel ||= inbox.channel
  end
end
