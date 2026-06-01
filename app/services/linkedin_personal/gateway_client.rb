class LinkedinPersonal::GatewayClient
  class GatewayError < StandardError; end

  RUNTIME_NOT_SYNCED_ERROR = /\bChannel\s+\d+\s+is not synced\b/i

  pattr_initialize [:channel!]

  def sync_channel!
    post("/internal/channels/#{channel.id}/sync", body: channel_payload)
  end

  def reconnect!
    post("/internal/channels/#{channel.id}/reconnect", body: {})
  end

  def history_sync!(force: true, reset_cursor: false)
    post(
      "/internal/channels/#{channel.id}/history-sync",
      body: {
        force: force,
        reset_cursor: reset_cursor
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

  def fetch_profile_avatar!(profile_urn:, avatar_fingerprint:)
    get_file_with_runtime_retry(
      "/internal/channels/#{channel.id}/contacts/#{CGI.escape(profile_urn)}/avatar",
      query: { fingerprint: avatar_fingerprint }
    )
  end

  def send_message!(message)
    conversation_urn, recipient_urn = outbound_target!(message)

    post_with_runtime_retry(
      "/internal/channels/#{channel.id}/messages",
      body: {
        conversation_urn: conversation_urn,
        recipient_urn: recipient_urn,
        text: message.outgoing_content,
        reply_to_message_id: message.content_attributes['in_reply_to_external_id'],
        attachments: serialize_attachments(message)
      }
    )
  end

  def edit_message!(message:, content:)
    conversation_urn, recipient_urn = outbound_target!(message)

    post_with_runtime_retry(
      "/internal/channels/#{channel.id}/messages/edit",
      body: {
        conversation_urn: conversation_urn,
        recipient_urn: recipient_urn,
        message_id: message.source_id,
        text: content
      }
    )
  end

  def delete_message!(message)
    conversation_urn, recipient_urn = outbound_target!(message)

    post_with_runtime_retry(
      "/internal/channels/#{channel.id}/messages/delete",
      body: {
        conversation_urn: conversation_urn,
        recipient_urn: recipient_urn,
        message_ids: [message.source_id].map(&:to_s).reject(&:blank?).uniq
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
        content_type: attachment.file.content_type
      }
    end
  end

  def outbound_target!(message)
    contact_inbox = message.conversation.contact_inbox
    recipient_urn = contact_inbox&.source_id.to_s.presence
    raise GatewayError, 'LinkedIn conversation is missing contact inbox source_id' if recipient_urn.blank?

    conversation_urn = message.conversation.additional_attributes['linkedin_conversation_urn'].to_s.presence ||
                       message.conversation.additional_attributes['conversation_urn'].to_s.presence
    [conversation_urn, recipient_urn]
  end

  def channel_payload
    {
      profile_urn: channel.profile_urn,
      display_name: channel.display_name,
      li_at: channel.li_at,
      jsessionid: channel.jsessionid,
      csrf_token: channel.csrf_token,
      x_li_track: channel.x_li_track,
      callback_url: channel.callback_webhook_url,
      webhook_secret: channel.webhook_secret,
      runtime_state: channel.runtime_state_payload,
      runtime_settings: LinkedinPersonal::Config.runtime_settings
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

    raise GatewayError, parsed[:error].presence || response.body.presence || 'LinkedIn gateway request failed'
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
    if response.success?
      return {
        body: response.body,
        content_type: response.headers['content-type'].to_s.split(';').first.presence || 'image/jpeg'
      }
    end

    parsed = response.parsed_response.is_a?(Hash) ? response.parsed_response.with_indifferent_access : {}
    raise GatewayError, parsed[:error].presence || response.body.presence || 'LinkedIn gateway file request failed'
  end

  def headers
    {
      'Authorization' => "Bearer #{gateway_token}",
      'Content-Type' => 'application/json'
    }
  end

  def base_url
    LinkedinPersonal::Config.gateway_url.presence || raise(GatewayError, 'LINKEDIN_PERSONAL_GATEWAY_URL is not configured')
  end

  def gateway_token
    LinkedinPersonal::Config.gateway_token.presence || raise(GatewayError, 'LINKEDIN_PERSONAL_GATEWAY_TOKEN is not configured')
  end

  def runtime_not_synced_error?(error)
    error.message.to_s.match?(RUNTIME_NOT_SYNCED_ERROR)
  end
end
