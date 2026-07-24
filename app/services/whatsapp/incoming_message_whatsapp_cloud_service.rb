# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/

class Whatsapp::IncomingMessageWhatsappCloudService < Whatsapp::IncomingMessageBaseService
  WHATSAPP_CLOUD_DELIVERY_STATUS_ORDER = {
    'sent' => 0,
    'delivered' => 1,
    'read' => 2
  }.freeze

  private

  def process_statuses
    status_payload = @processed_params[:statuses]&.first
    status_payload[:status] = 'read' if status_payload&.[](:status) == 'played'
    super
  end

  def after_message_persisted(message)
    super
    return if Current.suppress_runtime_events || outgoing_echo || message.blank? || !message.incoming?

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
    metadata_changed = persist_delivery_metadata(message, status)
    if lower_delivery_status?(message.status, status[:status])
      message.save! if metadata_changed
      return
    end

    super
  end

  def persist_delivery_metadata(message, status)
    delivery_metadata = status.to_h.with_indifferent_access.slice(:conversation, :pricing).deep_stringify_keys
    return false if delivery_metadata.empty?

    content_attributes = message.content_attributes.to_h.deep_stringify_keys
    updated_attributes = content_attributes.merge('whatsapp_delivery' => delivery_metadata)
    return false if updated_attributes == content_attributes

    message.content_attributes = updated_attributes
    true
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
