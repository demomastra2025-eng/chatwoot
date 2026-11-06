class TelegramPersonal::GatewayClient
  include TelegramPersonal::GatewayCallMethods

  GatewayError = TelegramPersonal::GatewayCallMethods::GatewayError
  RUNTIME_NOT_SYNCED_ERROR = /\bChannel\s+\d+\s+is not synced\b/i
  ENRICH_MEDIA_TIMEOUT_SECONDS = 180
  NETWORK_ERRORS = [HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, SystemCallError].freeze

  pattr_initialize [:channel!]

  def sync_channel!
    post("/internal/channels/#{channel.id}/sync", body: channel_payload)
  end

  def request_login_code!
    post("/internal/channels/#{channel.id}/auth/request-code", body: {})
  end

  def request_qr_login!
    post("/internal/channels/#{channel.id}/auth/request-qr", body: {})
  end

  def verify_login_code!(code:)
    post("/internal/channels/#{channel.id}/auth/verify-code", body: { code: code })
  end

  def verify_password!(password:)
    post("/internal/channels/#{channel.id}/auth/verify-password", body: { password: password })
  end

  def reconnect!
    post("/internal/channels/#{channel.id}/reconnect", body: {})
  end

  def history_sync!(force: true, reset_cursor: false, include_contacts: false, full: nil)
    body = { force: force, reset_cursor: reset_cursor, include_contacts: include_contacts }
    body[:full] = full unless full.nil?
    post("/internal/channels/#{channel.id}/history-sync", body: body)
  end

  def contacts_sync!(force: true)
    post("/internal/channels/#{channel.id}/contacts-sync", body: { force: force })
  end

  def disconnect!
    post("/internal/channels/#{channel.id}/disconnect", body: {})
  end

  def teardown_channel!
    delete("/internal/channels/#{channel.id}")
  end

  def diagnostics
    get("/internal/channels/#{channel.id}/diagnostics")
  end

  def fetch_profile_avatar!(peer_user_id:, avatar_fingerprint:)
    get_file_with_runtime_retry("/internal/channels/#{channel.id}/contacts/#{peer_user_id}/avatar", query: { fingerprint: avatar_fingerprint })
  end

  def send_message!(message)
    recipient_id, chat_id = outbound_target!(message)
    reply_to_id = TelegramPersonal::MessageSourceId.provider_id(message.content_attributes.to_h['in_reply_to_external_id']).presence
    body = {
      recipient_id: recipient_id, chat_id: chat_id, text: message.outgoing_content, text_format: 'html',
      reply_to_message_id: reply_to_id, attachments: serialize_attachments(message)
    }
    post_with_runtime_retry("/internal/channels/#{channel.id}/messages", body: body)
  end

  def edit_message!(message:, content:)
    recipient_id, chat_id = outbound_target!(message)
    rendered_content = Messages::MarkdownRendererService.new(content, 'Channel::TelegramPersonal', channel).render
    body = {
      recipient_id: recipient_id, chat_id: chat_id, message_id: provider_message_id_for(message),
      text: rendered_content, text_format: 'html'
    }
    post_with_runtime_retry("/internal/channels/#{channel.id}/messages/edit", body: body)
  end

  def delete_message!(message)
    recipient_id, chat_id = outbound_target!(message)
    body = { recipient_id: recipient_id, chat_id: chat_id, message_ids: provider_message_ids_for(message) }
    post_with_runtime_retry("/internal/channels/#{channel.id}/messages/delete", body: body)
  end

  def react_message!(message:, emoji:)
    recipient_id, chat_id = outbound_target!(message)
    body = { recipient_id: recipient_id, chat_id: chat_id, message_id: provider_message_id_for(message), emoji: emoji.to_s }
    post_with_runtime_retry("/internal/channels/#{channel.id}/messages/react", body: body)
  end

  def enrich_message_media!(chat_id:, peer_user_id:, message_id:, telegram_message_ids: [])
    stripped_ids = Array.wrap(telegram_message_ids).map { |id| TelegramPersonal::MessageSourceId.provider_id(id) }.reject(&:blank?).uniq
    body = {
      chat_id: chat_id, peer_user_id: peer_user_id,
      message_id: TelegramPersonal::MessageSourceId.provider_id(message_id), telegram_message_ids: stripped_ids
    }
    post_with_runtime_retry("/internal/channels/#{channel.id}/messages/enrich-media", body: body, timeout: ENRICH_MEDIA_TIMEOUT_SECONDS)
  end

  def mark_read!(recipient_id:, chat_id:, max_id:)
    body = { recipient_id: recipient_id, chat_id: chat_id, max_id: max_id }
    post_with_runtime_retry("/internal/channels/#{channel.id}/mark-read", body: body)
  end

  private

  def serialize_attachments(message)
    message.attachments.map do |att|
      {
        file_type: att.file_type, url: att.download_url, filename: att.file.filename.to_s,
        content_type: att.file.content_type, voice_note: voice_note_attachment?(message, att)
      }
    end
  end

  def voice_note_attachment?(message, attachment)
    attachment.file_type.to_s == 'audio' && ActiveModel::Type::Boolean.new.cast(message.content_attributes.to_h['voice_note'])
  end

  def provider_message_id_for(message)
    TelegramPersonal::MessageSourceId.provider_id(message.source_id)
  end

  def provider_message_ids_for(message)
    ids = Array.wrap(message.content_attributes['telegram_message_ids']).presence || [provider_message_id_for(message)]
    ids.map { |id| TelegramPersonal::MessageSourceId.provider_id(id) }.reject(&:blank?).uniq
  end

  def outbound_target!(message)
    recipient_id = message.conversation.contact_inbox&.source_id.to_s.presence
    raise GatewayError, 'Telegram Personal conversation is missing contact inbox source_id' if recipient_id.blank?

    chat_id = message.conversation.additional_attributes['chat_id'].to_s.presence || recipient_id
    [recipient_id, chat_id]
  end

  def channel_payload
    {
      api_id: channel.resolved_api_id, api_hash: channel.resolved_api_hash, phone_number: channel.phone_number,
      string_session: channel.string_session, callback_url: channel.callback_webhook_url,
      webhook_secret: channel.webhook_secret, runtime_state: channel.runtime_state_payload
    }
  end

  def get(path)
    parse_response(with_network_errors_wrapped { HTTParty.get("#{base_url}#{path}", headers: headers, timeout: 30) })
  end

  def post(path, body:, timeout: 60)
    parse_response(with_network_errors_wrapped { HTTParty.post("#{base_url}#{path}", headers: headers, body: body.to_json, timeout: timeout) })
  end

  def post_with_runtime_retry(path, body:, timeout: 60)
    post(path, body: body, timeout: timeout)
  rescue GatewayError => e
    raise unless runtime_not_synced_error?(e)

    sync_channel!
    post(path, body: body, timeout: timeout)
  end

  def delete(path)
    parse_response(with_network_errors_wrapped { HTTParty.delete("#{base_url}#{path}", headers: headers, timeout: 30) })
  end

  def parse_response(response)
    parsed = response.parsed_response.is_a?(Hash) ? response.parsed_response.with_indifferent_access : {}
    return parsed if response.success?

    raise GatewayError.new(parsed[:error].presence || response.body.presence || 'Telegram Personal gateway request failed',
                           http_status: response.code)
  end

  def with_network_errors_wrapped
    yield
  rescue *NETWORK_ERRORS => e
    raise GatewayError, "Telegram Personal gateway network error: #{e.message}"
  end

  def headers
    { 'Authorization' => "Bearer #{gateway_token}", 'Content-Type' => 'application/json' }
  end

  def base_url
    ENV.fetch('TELEGRAM_PERSONAL_GATEWAY_URL')
  end

  def gateway_token
    ENV.fetch('TELEGRAM_PERSONAL_GATEWAY_TOKEN')
  end

  def runtime_not_synced_error?(error)
    error.message.to_s.match?(RUNTIME_NOT_SYNCED_ERROR)
  end
end
