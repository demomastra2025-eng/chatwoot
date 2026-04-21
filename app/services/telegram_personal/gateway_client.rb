class TelegramPersonal::GatewayClient
  class GatewayError < StandardError; end
  RUNTIME_NOT_SYNCED_ERROR = /\bChannel\s+\d+\s+is not synced\b/i

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

  def history_sync!(force: true, reset_cursor: false, include_contacts: false)
    post(
      "/internal/channels/#{channel.id}/history-sync",
      body: {
        force: force,
        reset_cursor: reset_cursor,
        include_contacts: include_contacts
      }
    )
  end

  def contacts_sync!(force: true)
    post(
      "/internal/channels/#{channel.id}/contacts-sync",
      body: {
        force: force
      }
    )
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
    get_file_with_runtime_retry(
      "/internal/channels/#{channel.id}/contacts/#{peer_user_id}/avatar",
      query: { fingerprint: avatar_fingerprint }
    )
  end

  def send_message!(message)
    recipient_id, chat_id = outbound_target!(message)

    post_with_runtime_retry(
      "/internal/channels/#{channel.id}/messages",
      body: {
        recipient_id: recipient_id,
        chat_id: chat_id,
        text: message.outgoing_content,
        reply_to_message_id: message.content_attributes['in_reply_to_external_id'],
        attachments: serialize_attachments(message)
      }
    )
  end

  def edit_message!(message:, content:)
    recipient_id, chat_id = outbound_target!(message)

    post_with_runtime_retry(
      "/internal/channels/#{channel.id}/messages/edit",
      body: {
        recipient_id: recipient_id,
        chat_id: chat_id,
        message_id: message.source_id,
        text: content
      }
    )
  end

  def delete_message!(message)
    recipient_id, chat_id = outbound_target!(message)

    post_with_runtime_retry(
      "/internal/channels/#{channel.id}/messages/delete",
      body: {
        recipient_id: recipient_id,
        chat_id: chat_id,
        message_ids: provider_message_ids_for(message)
      }
    )
  end

  def mark_read!(recipient_id:, chat_id:, max_id:)
    post_with_runtime_retry(
      "/internal/channels/#{channel.id}/mark-read",
      body: {
        recipient_id: recipient_id,
        chat_id: chat_id,
        max_id: max_id
      }
    )
  end

  private

  def serialize_attachments(message)
    message.attachments.map do |attachment|
      {
        file_type: attachment.file_type,
        url: attachment.download_url,
        filename: attachment.file.filename.to_s,
        content_type: attachment.file.content_type,
        voice_note: voice_note_attachment?(message, attachment)
      }
    end
  end

  def voice_note_attachment?(message, attachment)
    attachment.file_type.to_s == 'audio' && ActiveModel::Type::Boolean.new.cast(message.content_attributes.to_h['voice_note'])
  end

  def provider_message_ids_for(message)
    ids = Array.wrap(message.content_attributes['telegram_message_ids']).presence || [message.source_id]
    ids.map(&:to_s).reject(&:blank?).uniq
  end

  def outbound_target!(message)
    recipient_id = message.conversation.contact_inbox&.source_id.to_s.presence
    raise GatewayError, 'Telegram Personal conversation is missing contact inbox source_id' if recipient_id.blank?

    chat_id = message.conversation.additional_attributes['chat_id'].to_s.presence || recipient_id
    [recipient_id, chat_id]
  end

  def channel_payload
    {
      api_id: channel.resolved_api_id,
      api_hash: channel.resolved_api_hash,
      phone_number: channel.phone_number,
      string_session: channel.string_session,
      callback_url: channel.callback_webhook_url,
      webhook_secret: channel.webhook_secret,
      runtime_state: channel.runtime_state_payload
    }
  end

  def get(path)
    response = HTTParty.get("#{base_url}#{path}", headers: headers, timeout: 30)
    parse_response(response)
  end

  def post(path, body:)
    response = HTTParty.post("#{base_url}#{path}", headers: headers, body: body.to_json, timeout: 60)
    parse_response(response)
  end

  def post_with_runtime_retry(path, body:)
    post(path, body: body)
  rescue GatewayError => e
    raise unless runtime_not_synced_error?(e)

    sync_channel!
    post(path, body: body)
  end

  def delete(path)
    response = HTTParty.delete("#{base_url}#{path}", headers: headers, timeout: 30)
    parse_response(response)
  end

  def parse_response(response)
    parsed = response.parsed_response.is_a?(Hash) ? response.parsed_response.with_indifferent_access : {}
    return parsed if response.success?

    raise GatewayError, parsed[:error].presence || response.body.presence || 'Telegram Personal gateway request failed'
  end

  def parse_file_response(response)
    if response.success?
      return {
        body: response.body,
        content_type: response.headers['content-type'].to_s.split(';').first.presence || 'image/jpeg'
      }
    end

    parsed = response.parsed_response.is_a?(Hash) ? response.parsed_response.with_indifferent_access : {}
    raise GatewayError, parsed[:error].presence || response.body.presence || 'Telegram Personal gateway file request failed'
  end

  def get_file_with_runtime_retry(path, query:)
    get_file(path, query: query)
  rescue GatewayError => e
    raise unless runtime_not_synced_error?(e)

    sync_channel!
    get_file(path, query: query)
  end

  def get_file(path, query:)
    response = HTTParty.get(
      "#{base_url}#{path}",
      headers: headers.except('Content-Type'),
      query: query,
      timeout: 60
    )
    parse_file_response(response)
  end

  def headers
    {
      'Authorization' => "Bearer #{gateway_token}",
      'Content-Type' => 'application/json'
    }
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
