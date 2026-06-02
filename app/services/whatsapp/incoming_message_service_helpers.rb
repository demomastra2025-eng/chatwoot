module Whatsapp::IncomingMessageServiceHelpers
  def download_attachment_file(attachment_payload)
    Down.download(inbox.channel.media_url(attachment_payload[:id]), headers: inbox.channel.api_headers)
  end

  def conversation_params
    {
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
    }
  end

  def processed_params
    @processed_params ||= params
  end

  def account
    @account ||= inbox.account
  end

  def message_type
    messages_data.first[:type].to_s
  end

  def message_content(message)
    # TODO: map interactive messages back to button messages in chatwoot
    message.dig(:text, :body) ||
      message.dig(:button, :text) ||
      message.dig(:interactive, :button_reply, :title) ||
      message.dig(:interactive, :list_reply, :title) ||
      message.dig(:name, :formatted_name) ||
      unsupported_message_content(message)
  end

  def message_content_attributes(message)
    interactive_button_reply = message.dig(:interactive, :button_reply)
    interactive_list_reply = message.dig(:interactive, :list_reply)
    button = message[:button]

    {
      whatsapp_message_type: message[:type],
      interactive_reply_type: message.dig(:interactive, :type),
      interactive_reply_id: interactive_button_reply&.[](:id) || interactive_list_reply&.[](:id),
      interactive_reply_title: interactive_button_reply&.[](:title) || interactive_list_reply&.[](:title),
      button_payload: button&.[](:payload),
      button_text: button&.[](:text),
      whatsapp_unavailable_message: unavailable_whatsapp_message?(message),
      whatsapp_error_code: unavailable_whatsapp_error(message)&.[](:code),
      whatsapp_error_title: unavailable_whatsapp_error(message)&.[](:title)
    }.compact
  end

  def file_content_type(file_type)
    return :image if %w[image sticker].include?(file_type)
    return :audio if %w[audio voice].include?(file_type)
    return :video if ['video'].include?(file_type)
    return :location if ['location'].include?(file_type)
    return :contact if ['contacts'].include?(file_type)

    :file
  end

  def unprocessable_message_type?(message)
    type = (message.is_a?(Hash) ? message[:type] : message).to_s
    return false if type == 'unsupported' && unavailable_whatsapp_message?(message)

    %w[reaction ephemeral unsupported request_welcome].include?(type)
  end

  def unavailable_whatsapp_message?(message)
    message.is_a?(Hash) && message[:type].to_s == 'unsupported' && unavailable_whatsapp_error(message).present?
  end

  def unavailable_whatsapp_error(message)
    Array(message[:errors]).first
  end

  def unsupported_message_content(message)
    return unless unavailable_whatsapp_message?(message)

    error_title = unavailable_whatsapp_error(message)&.[](:title).presence || 'Message is unavailable'
    "WhatsApp message unavailable: #{error_title}"
  end

  def processed_waid(waid)
    Whatsapp::PhoneNumberNormalizationService.new(inbox).normalize_and_find_contact_by_provider(waid, :cloud)
  end

  def error_webhook_event?(message)
    return false if unavailable_whatsapp_message?(message)

    message.key?('errors')
  end

  def log_error(message)
    Rails.logger.warn "Whatsapp Error: #{message['errors'][0]['title']} - contact: #{message['from']}"
  end

  def process_in_reply_to(message)
    @in_reply_to_external_id = message['context']&.[]('id')
  end

  def find_message_by_source_id(source_id)
    return unless source_id

    @message = Message.find_by(source_id: source_id)
  end

  def lock_message_source_id!
    return false if messages_data.blank?

    Whatsapp::MessageDedupLock.new(messages_data.first[:id]).acquire!
  end
end
