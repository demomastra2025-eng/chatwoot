class TelegramCalls::GatewaySoftphoneClient
  DEFAULT_TIMEOUT = 15
  RECORDING_TIMEOUT = 30

  def initialize(base_url: TelegramCalls::Config.gateway_url, token: TelegramCalls::Config.gateway_token)
    @base_url = base_url.to_s.chomp('/')
    @token = token.to_s
  end

  def configured?
    @base_url.present? && @token.present?
  end

  def create_leg!(payload)
    worker = TelegramCalls::Config.operator_worker
    return post_json!('/internal/operator-softphone/legs', payload) unless worker

    begin
      post_json!('/internal/operator-softphone/legs', payload.merge(worker: worker))
    rescue StandardError
      raise Telephony::Error.new(
        code: 'TELEGRAM_GATEWAY_ERROR', message: 'Telegram voice gateway request failed', status: :bad_gateway
      ), cause: nil
    end
  end

  def attach_webrtc!(leg_id:, sdp_offer:, ice_servers: [])
    post_json!(
      "/internal/operator-softphone/legs/#{encode(leg_id)}/attach-webrtc",
      { sdp_offer: sdp_offer, ice_servers: ice_servers }
    )
  end

  def bridge_telegram!(leg_id:, payload:)
    post_json!("/internal/operator-softphone/legs/#{encode(leg_id)}/bridge-telegram", payload)
  end

  def bridge_sip!(leg_id:, line_key:, janus_call_id: nil, call_ref: nil)
    post_json!(
      "/internal/operator-softphone/legs/#{encode(leg_id)}/bridge-sip",
      { line_key: line_key, janus_call_id: janus_call_id, call_ref: call_ref }.compact
    )
  end

  def dial_sip!(leg_id:, line_key:, number:, call_ref: nil)
    post_json!(
      "/internal/operator-softphone/legs/#{encode(leg_id)}/dial-sip",
      { line_key: line_key, to_number: number, call_ref: call_ref }.compact
    )
  end

  def terminate_leg!(leg_id:, reason: 'terminated')
    post_json!(
      "/internal/operator-softphone/legs/#{encode(leg_id)}/terminate",
      { reason: reason }
    )
  end

  def download_recording!(leg_id:, side: 'combined')
    ensure_configured!
    response = HTTParty.get(
      "#{@base_url}/internal/operator-softphone/legs/#{encode(leg_id)}/recording",
      query: { side: side },
      headers: auth_headers,
      timeout: RECORDING_TIMEOUT
    )
    raise_gateway_error!(response) unless response.success?

    response.body
  end

  def sync_sip_lines!(payload)
    post_json!('/internal/operator-softphone/sip-lines/sync', payload, timeout: 25)
  end

  def remove_sip_line_group!(group_key:)
    ensure_configured!
    response = HTTParty.delete(
      "#{@base_url}/internal/operator-softphone/sip-lines/#{encode(group_key)}",
      headers: auth_headers,
      timeout: DEFAULT_TIMEOUT
    )
    raise_gateway_error!(response) unless response.success?

    parsed_hash(response)
  end

  def decline_sip_call!(line_key:, janus_call_id: nil, call_ref: nil)
    post_json!(
      "/internal/operator-softphone/sip-lines/#{encode(line_key)}/decline",
      { janus_call_id: janus_call_id, call_ref: call_ref }.compact
    )
  end

  private

  def post_json!(path, payload, timeout: DEFAULT_TIMEOUT)
    ensure_configured!
    response = HTTParty.post(
      "#{@base_url}#{path}",
      headers: auth_headers.merge('Content-Type' => 'application/json'),
      body: payload.to_json,
      timeout: timeout
    )
    raise_gateway_error!(response) unless response.success?

    parsed_hash(response)
  end

  def auth_headers
    { 'Authorization' => "Bearer #{@token}" }
  end

  def encode(segment)
    ERB::Util.url_encode(segment.to_s)
  end

  def parsed_hash(response)
    parsed = response.parsed_response
    parsed.is_a?(Hash) ? parsed.deep_stringify_keys : {}
  end

  def ensure_configured!
    return if configured?

    raise Telephony::Error.new(
      code: 'TELEGRAM_GATEWAY_UNCONFIGURED',
      message: 'Telegram voice gateway is not configured',
      status: :service_unavailable
    )
  end

  def raise_gateway_error!(response)
    parsed = response.parsed_response
    detail = parsed.is_a?(Hash) ? (parsed['detail'] || parsed['error']) : response.body.to_s.truncate(200)
    raise Telephony::Error.new(
      code: 'TELEGRAM_GATEWAY_ERROR',
      message: detail.presence || "Gateway HTTP #{response.code}",
      status: :bad_gateway
    )
  end
end
