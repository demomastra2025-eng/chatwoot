# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/

class Whatsapp::IncomingMessageWhatsappCloudService < Whatsapp::IncomingMessageBaseService
  class PreparedAttachmentError < StandardError; end

  WHATSAPP_CLOUD_DELIVERY_STATUS_ORDER = {
    'sent' => 0,
    'delivered' => 1,
    'read' => 2
  }.freeze

  attr_reader :prepared_attachment

  # rubocop:disable Metrics/ParameterLists
  def initialize(
    inbox:,
    params:,
    outgoing_echo: nil,
    prepared_attachment: nil,
    require_prepared_attachment: false,
    history_import: false
  )
    @prepared_attachment = prepared_attachment
    @require_prepared_attachment = require_prepared_attachment
    @history_import = history_import == true
    super(inbox: inbox, params: params, outgoing_echo: outgoing_echo)
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    super
  ensure
    @fallback_prepared_attachment&.close
  end

  private

  def message_content_attributes(message)
    attributes = super
    return attributes unless @history_import

    history_status = message.dig(:history_context, :status).presence || message[:status]
    attributes.merge(
      imported_history: true,
      whatsapp_history_import: true,
      whatsapp_history_status: history_status,
      whatsapp_history_original_type: message[:type]
    ).compact
  end

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
    download = prepared_attachment || prepare_fallback_attachment!
    raise PreparedAttachmentError, 'Prepared WhatsApp media did not match the attachment' unless download.matches?(attachment_payload)
    raise PreparedAttachmentError, 'Prepared WhatsApp media file is unavailable' if download.file.blank?

    download.file
  end

  def prepare_fallback_attachment!
    raise PreparedAttachmentError, 'Prepared WhatsApp media is required for live webhook dispatch' if @require_prepared_attachment

    @fallback_prepared_attachment = Whatsapp::CloudMediaDownload.prepare(
      channel: inbox.channel,
      params: params,
      outgoing_echo: outgoing_echo
    )
    raise PreparedAttachmentError, 'WhatsApp media payload could not be prepared' if @fallback_prepared_attachment.blank?

    @fallback_prepared_attachment.download!
    @fallback_prepared_attachment
  end
end
