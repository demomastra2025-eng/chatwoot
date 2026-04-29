class Weixin::GatewayClient
  class GatewayError < StandardError; end

  DEVELOPMENT_GATEWAY_URL = 'http://127.0.0.1:8097'.freeze
  DEVELOPMENT_GATEWAY_TOKEN = 'local-weixin-gateway'.freeze
  RUNTIME_NOT_SYNCED_ERROR = /\bChannel\s+\d+\s+is not synced\b/i
  SENSITIVE_ERROR_PATTERN = /(authorization|bearer|token|secret|password|api[_-]?key|connection[_-]?string)(["'\s:=]+)([^"'\s,}]+)/i
  TRANSPORT_ERRORS = [
    HTTParty::Error,
    SocketError,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    Net::OpenTimeout,
    Net::ReadTimeout,
    EOFError,
    Timeout::Error
  ].freeze

  pattr_initialize [:channel!]

  def sync_channel!
    post("/internal/channels/#{channel.id}/sync", body: channel_payload)
  end

  def request_qr_login!
    post("/internal/channels/#{channel.id}/auth/request-qr", body: {})
  end

  def reconnect!
    post("/internal/channels/#{channel.id}/reconnect", body: {})
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

  def send_message!(message)
    recipient_id, chat_id = outbound_target!(message)

    post_with_runtime_retry(
      "/internal/channels/#{channel.id}/messages",
      body: {
        recipient_id: recipient_id,
        chat_id: chat_id,
        text: message.outgoing_content,
        context_token: outbound_context_token(recipient_id),
        reply_to_message_id: message.content_attributes['in_reply_to_external_id'],
        attachments: serialize_attachments(message)
      }
    )
  end

  private

  def channel_payload
    {
      ilink_token: channel.resolved_ilink_token,
      provider_account_id: channel.provider_account_id,
      display_name: channel.display_name,
      context_token: channel.context_token,
      context_tokens: channel.context_tokens_payload,
      callback_url: channel.callback_webhook_url,
      webhook_secret: channel.webhook_secret,
      runtime_state: channel.runtime_state_payload
    }
  end

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
    recipient_id = message.conversation.contact_inbox&.source_id.to_s.presence
    raise GatewayError, 'Weixin conversation is missing contact inbox source_id' if recipient_id.blank?

    chat_id = message.conversation.additional_attributes['weixin_chat_id'].to_s.presence || recipient_id
    [recipient_id, chat_id]
  end

  def outbound_context_token(recipient_id)
    channel.context_token_for(recipient_id)
  end

  def get(path)
    with_transport_error_handling do
      response = HTTParty.get("#{base_url}#{path}", headers: headers.except('Content-Type'), timeout: 30)
      parse_response(response)
    end
  end

  def post(path, body:)
    with_transport_error_handling do
      response = HTTParty.post("#{base_url}#{path}", headers: headers, body: body.to_json, timeout: 60)
      parse_response(response)
    end
  end

  def post_with_runtime_retry(path, body:)
    post(path, body: body)
  rescue GatewayError => e
    raise unless runtime_not_synced_error?(e)

    sync_channel!
    post(path, body: body)
  end

  def delete(path)
    with_transport_error_handling do
      response = HTTParty.delete("#{base_url}#{path}", headers: headers.except('Content-Type'), timeout: 30)
      parse_response(response)
    end
  end

  def parse_response(response)
    parsed = response.parsed_response.is_a?(Hash) ? response.parsed_response.with_indifferent_access : {}
    return parsed if response.success?

    raise GatewayError, redact_error_message(parsed[:error].presence || response.body.presence || 'Weixin gateway request failed')
  end

  def headers
    {
      'Authorization' => "Bearer #{gateway_token}",
      'Content-Type' => 'application/json'
    }
  end

  def base_url
    gateway_setting('WEIXIN_GATEWAY_URL', DEVELOPMENT_GATEWAY_URL).delete_suffix('/')
  end

  def gateway_token
    gateway_setting('WEIXIN_GATEWAY_TOKEN', DEVELOPMENT_GATEWAY_TOKEN)
  end

  def gateway_setting(key, development_default)
    value = ENV.fetch(key, nil).presence
    return value if value.present?
    return development_default if Rails.env.development?

    raise GatewayError, "Weixin gateway is not configured: #{key} is missing"
  end

  def with_transport_error_handling
    yield
  rescue GatewayError
    raise
  rescue *TRANSPORT_ERRORS => e
    raise GatewayError, "Weixin gateway unavailable: #{redact_error_message(e.message.presence || e.class.name)}"
  end

  def runtime_not_synced_error?(error)
    error.message.to_s.match?(RUNTIME_NOT_SYNCED_ERROR)
  end

  def redact_error_message(message)
    message.to_s.gsub(SENSITIVE_ERROR_PATTERN, '\\1\\2[REDACTED]')
  end
end
