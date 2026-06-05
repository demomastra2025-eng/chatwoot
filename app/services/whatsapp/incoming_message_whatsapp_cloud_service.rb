# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/

class Whatsapp::IncomingMessageWhatsappCloudService < Whatsapp::IncomingMessageBaseService
  WHATSAPP_CLOUD_DELIVERY_STATUS_ORDER = {
    'sent' => 0,
    'delivered' => 1,
    'read' => 2
  }.freeze

  private

  def after_message_persisted(message)
    super
    return if outgoing_echo || message.blank? || !message.incoming?

    Confirmations::WhatsappReplyResolver.new(
      account: inbox.account,
      conversation: message.conversation,
      message: message
    ).perform
  rescue StandardError => e
    Rails.logger.warn("[WhatsApp Cloud] Confirmation reply resolution failed: #{e.class}: #{e.message}")
  end

  def processed_params
    @processed_params ||= params[:entry].try(:first).try(:[], 'changes').try(:first).try(:[], 'value')
  end

  def update_message_with_status(message, status)
    return if lower_delivery_status?(message.status, status[:status])

    super
  end

  def lower_delivery_status?(current_status, incoming_status)
    current_status_order = WHATSAPP_CLOUD_DELIVERY_STATUS_ORDER[current_status.to_s]
    incoming_status_order = WHATSAPP_CLOUD_DELIVERY_STATUS_ORDER[incoming_status.to_s]

    current_status_order.present? && incoming_status_order.present? && incoming_status_order < current_status_order
  end

  def download_attachment_file(attachment_payload)
    url_response = HTTParty.get(
      inbox.channel.media_url(attachment_payload[:id]),
      headers: inbox.channel.api_headers
    )
    # This url response will be failure if the access token has expired.
    inbox.channel.authorization_error! if url_response.unauthorized?
    Down.download(url_response.parsed_response['url'], headers: inbox.channel.api_headers) if url_response.success?
  end
end
