module TelegramPersonal::GatewayCallMethods
  class GatewayError < StandardError
    attr_reader :http_status, :code

    def initialize(message = nil, http_status: nil, code: nil)
      @http_status = http_status
      @code = code
      super(message)
    end

    def media_leg_closed?
      code.to_s == 'media_leg_closed' ||
        http_status.to_i == 404 ||
        message.to_s.match?(/\b(not found|already ended|closed|terminated|media_leg_closed)\b/i)
    end
  end

  def prepare_outbound_call!(recipient_id:, phone_number: nil, username: nil)
    body = { recipient_id: recipient_id.to_s, phone_number: phone_number.presence, username: username.presence }.compact
    post_with_runtime_retry("/internal/channels/#{channel.id}/calls/prepare-outbound", body: body)
  end

  def dial_call!(call_ref:)
    post_with_runtime_retry(call_endpoint(call_ref, 'dial'), body: {})
  end

  def accept_call!(call_ref:)
    post_with_runtime_retry(call_endpoint(call_ref, 'accept'), body: {})
  end

  def set_call_agent_answer!(call_ref:, sdp_answer:, peer_id: nil)
    body = { sdp_answer: sdp_answer, peer_id: peer_id.presence }.compact
    post_with_runtime_retry(call_endpoint(call_ref, 'agent-answer'), body: body)
  end

  def reconnect_call!(call_ref:)
    post_with_runtime_retry(call_endpoint(call_ref, 'reconnect'), body: {})
  end

  def reject_call!(call_ref:, reason: 'busy')
    post_with_runtime_retry(call_endpoint(call_ref, 'reject'), body: { reason: reason })
  end

  def terminate_call!(call_ref:)
    post_with_runtime_retry(call_endpoint(call_ref, 'terminate'), body: {})
  end

  def download_call_recording!(call_ref:, side: 'combined')
    file = get_file_with_runtime_retry(call_endpoint(call_ref, 'recording'), query: { side: side.to_s })
    file[:body]
  end

  private

  def call_endpoint(call_ref, action)
    "/internal/channels/#{channel.id}/calls/#{ERB::Util.url_encode(call_ref.to_s)}/#{action}"
  end

  def get_file_with_runtime_retry(path, query:)
    get_file(path, query: query)
  rescue GatewayError => e
    raise unless runtime_not_synced_error?(e)

    sync_channel!
    get_file(path, query: query)
  end

  def get_file(path, query:)
    response = with_network_errors_wrapped do
      HTTParty.get("#{base_url}#{path}", headers: headers.except('Content-Type'), query: query, timeout: 60)
    end
    parse_file_response(response)
  end

  def parse_file_response(response)
    if response.success?
      content_type = response.headers['content-type'].to_s.split(';').first.presence || 'image/jpeg'
      return { body: response.body, content_type: content_type }
    end

    parsed = response.parsed_response.is_a?(Hash) ? response.parsed_response.with_indifferent_access : {}
    raise GatewayError.new(
      parsed[:error].presence || response.body.presence || 'Telegram Personal gateway file request failed',
      http_status: response.code
    )
  end
end
