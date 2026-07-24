module Whatsapp::IncomingMessageServiceHelpers
  include Whatsapp::IncomingDedupMessageHelpers
  include Whatsapp::IncomingRichMessageHelpers
  include Whatsapp::IncomingStatusMessageHelpers

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
    message.dig(:text, :body) ||
      message.dig(:button, :text) ||
      message.dig(:interactive, :button_reply, :title) ||
      message.dig(:interactive, :list_reply, :title) ||
      rich_message_content(message) ||
      unsupported_message_content(message)
  end

  def message_content_attributes(message)
    attributes = interactive_message_content_attributes(message)
    attributes.merge!(unavailable_message_content_attributes(message))
    attributes.merge!(rich_message_content_attributes(message))

    meta_referral = Meta::AdReferralNormalizer.from_whatsapp_message(message)
    attributes[:meta_referral] = meta_referral if meta_referral.present?
    attributes
  end

  def interactive_message_content_attributes(message)
    interactive_button_reply = message.dig(:interactive, :button_reply)
    interactive_list_reply = message.dig(:interactive, :list_reply)
    button = message[:button]

    {
      whatsapp_message_type: message[:type],
      interactive_reply_type: message.dig(:interactive, :type),
      interactive_reply_id: interactive_button_reply&.[](:id) || interactive_list_reply&.[](:id),
      interactive_reply_title: interactive_button_reply&.[](:title) || interactive_list_reply&.[](:title),
      button_payload: button&.[](:payload),
      button_text: button&.[](:text)
    }.compact
  end

  def unavailable_message_content_attributes(message)
    unsupported_message = unsupported_whatsapp_message?(message)
    unavailable_error = unavailable_whatsapp_error(message)

    {
      whatsapp_unavailable_message: (true if unsupported_message),
      is_unsupported: (true if unsupported_message),
      whatsapp_error_code: unavailable_error&.[](:code),
      whatsapp_error_title: unavailable_error&.[](:title),
      whatsapp_error_message: unavailable_whatsapp_error_message(unavailable_error)
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

    %w[reaction ephemeral request_welcome].include?(type)
  end

  def unsupported_whatsapp_message?(message)
    message.is_a?(Hash) && message[:type].to_s == 'unsupported'
  end

  def unavailable_whatsapp_message?(message)
    unsupported_whatsapp_message?(message) && unavailable_whatsapp_error(message).present?
  end

  def unavailable_whatsapp_error(message)
    Array(message[:errors]).first
  end

  def unsupported_message_content(message)
    return unless unsupported_whatsapp_message?(message)

    error_message = unavailable_whatsapp_error_message(unavailable_whatsapp_error(message))
    return I18n.t('conversations.messages.whatsapp.unavailable', error_title: error_message) if error_message.present?

    I18n.t('conversations.messages.whatsapp.unsupported_message', default: 'This message is unavailable.')
  end

  def unavailable_whatsapp_error_message(error)
    error&.dig(:error_data, :details).presence || error&.[](:message).presence || error&.[](:title).presence
  end

  def process_in_reply_to(message)
    @in_reply_to_external_id = message['context']&.[]('id')
  end
end
