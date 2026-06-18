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
      nfm_reply_content(message) ||
      message.dig(:name, :formatted_name) ||
      unsupported_message_content(message)
  end

  def message_content_attributes(message)
    interactive_button_reply = message.dig(:interactive, :button_reply)
    interactive_list_reply = message.dig(:interactive, :list_reply)
    button = message[:button]
    unsupported_message = unsupported_whatsapp_message?(message)
    unavailable_error = unavailable_whatsapp_error(message)

    {
      whatsapp_message_type: message[:type],
      interactive_reply_type: message.dig(:interactive, :type),
      interactive_reply_id: interactive_button_reply&.[](:id) || interactive_list_reply&.[](:id),
      interactive_reply_title: interactive_button_reply&.[](:title) || interactive_list_reply&.[](:title),
      button_payload: button&.[](:payload),
      button_text: button&.[](:text),
      whatsapp_unavailable_message: (true if unsupported_message),
      is_unsupported: (true if unsupported_message),
      whatsapp_error_code: unavailable_error&.[](:code),
      whatsapp_error_title: unavailable_error&.[](:title)
    }.merge(nfm_reply_content_attributes(message)).compact
  end

  def nfm_reply_content_attributes(message)
    nfm_reply = interactive_nfm_reply(message)
    return {} if nfm_reply.blank?

    response_json = nfm_reply[:response_json]
    parsed_response = parse_nfm_reply_response_json(response_json)
    flow_token = parsed_response[:value].is_a?(Hash) ? parsed_response[:value]['flow_token'] : nil
    flow_session = whatsapp_flow_session_for_token(flow_token)
    redacted_response = redact_flow_token(parsed_response[:value])

    {
      flow_reply_name: nfm_reply[:name],
      flow_reply_body: nfm_reply[:body],
      flow_response_json: flow_response_json(redacted_response, response_json),
      flow_response: redacted_response,
      flow_parse_error: parsed_response[:error],
      flow_token_prefix: flow_token_prefix(flow_token),
      flow_session_id: flow_session&.id
    }
  end

  def nfm_reply_content(message)
    nfm_reply = interactive_nfm_reply(message)
    return if nfm_reply.blank?

    nfm_reply[:body].presence ||
      ("Flow submitted: #{nfm_reply[:name]}" if nfm_reply[:name].present?) ||
      'Flow submitted'
  end

  def interactive_nfm_reply(message)
    return unless message.dig(:interactive, :type).to_s == 'nfm_reply'

    message.dig(:interactive, :nfm_reply) || {}
  end

  def parse_nfm_reply_response_json(response_json)
    return {} if response_json.blank?

    parsed_value = JSON.parse(response_json)
    return { value: parsed_value } if parsed_value.is_a?(Hash)

    { error: 'response_json must be a JSON object' }
  rescue JSON::ParserError => e
    { error: e.message }
  end

  def redact_flow_token(value)
    return value unless value.is_a?(Hash)

    value.deep_dup.tap do |payload|
      payload['flow_token'] = '[REDACTED]' if payload.key?('flow_token')
    end
  end

  def flow_response_json(redacted_response, original_response_json)
    return redacted_response.to_json if redacted_response.is_a?(Hash)

    original_response_json
  end

  def whatsapp_flow_session_for_token(flow_token)
    return if flow_token.blank?

    Whatsapp::FlowSession.find_by_token(flow_token, account_id: inbox.account_id, inbox_id: inbox.id)
  end

  def flow_token_prefix(flow_token)
    return if flow_token.blank?

    Whatsapp::FlowSession.prefix_token(flow_token)
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

    error_title = unavailable_whatsapp_error(message)&.[](:title).presence
    return I18n.t('conversations.messages.whatsapp.unavailable', error_title: error_title) if error_title.present?

    I18n.t('conversations.messages.whatsapp.unsupported_message', default: 'This message is unavailable.')
  end

  def processed_waid(waid)
    source_id = Whatsapp::ContactIdentityResolver.phone_source_id(waid)
    return if source_id.blank?

    Whatsapp::PhoneNumberNormalizationService.new(inbox).normalize_and_find_contact_by_provider(source_id, :cloud)
  end

  def error_webhook_event?(message)
    return false if unsupported_whatsapp_message?(message)

    message.key?('errors')
  end

  def log_error(message)
    Rails.logger.warn "Whatsapp Error: #{message['errors'][0]['title']} - contact: #{message['from']}"
  end

  def process_in_reply_to(message)
    @in_reply_to_external_id = message['context']&.[]('id')
  end

  def update_whatsapp_identifiers_from_status(status)
    contact_inbox = @message&.conversation&.contact_inbox
    return if contact_inbox.blank?

    Whatsapp::IdentifierSyncService.new(contact_inbox: contact_inbox, contact: contact_inbox.contact).perform(
      source_ids: status_source_ids(status),
      phone_number: status_phone_number(status)
    )
  end

  def status_source_ids(status)
    contact_params = @processed_params[:contacts]&.first || {}

    [
      status_phone_source_id(status),
      Whatsapp::ContactIdentityResolver.bsuid_source_id(status[:recipient_user_id]),
      Whatsapp::ContactIdentityResolver.bsuid_source_id(status[:recipient_parent_user_id]),
      Whatsapp::ContactIdentityResolver.bsuid_source_id(contact_params[:user_id]),
      Whatsapp::ContactIdentityResolver.bsuid_source_id(contact_params[:parent_user_id])
    ].compact_blank.uniq
  end

  def status_phone_number(status)
    Whatsapp::ContactIdentityResolver.phone_number_for(status_phone_source_id(status))
  end

  def status_phone_source_id(status)
    contact_params = @processed_params[:contacts]&.first || {}

    processed_waid(contact_params[:wa_id].presence || status[:recipient_id])
  end

  def find_message_by_source_id(source_id)
    return unless source_id

    @message = inbox.messages.find_by(source_id: source_id.to_s)
  end

  def lock_message_source_id!
    return false if messages_data.blank?

    Whatsapp::MessageDedupLock.new(inbox_id: inbox.id, source_id: messages_data.first[:id]).acquire!
  end
end
