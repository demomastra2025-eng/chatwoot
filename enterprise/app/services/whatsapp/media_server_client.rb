class Whatsapp::MediaServerClient
  class ConnectionError < StandardError; end

  class SessionError < StandardError
    attr_reader :http_status, :response_body, :error_code

    def initialize(message, http_status: nil, response_body: nil, error_code: nil)
      super(message)
      @http_status = http_status
      @response_body = response_body
      @error_code = error_code
    end

    def media_leg_closed?
      %w[media_leg_closed media_session_closed].include?(error_code) || http_status.to_i == 404
    end
  end

  TIMEOUT = 10

  def create_session(call_id:, direction:, sdp_offer:, ice_servers:, account_id: nil)
    body = { call_id: call_id, direction: direction, meta_sdp_offer: sdp_offer,
             ice_servers: normalize_ice_servers(ice_servers), account_id: account_id&.to_s }.compact
    post('/sessions', body)
  end

  def generate_agent_offer(session_id)
    post("/sessions/#{session_id}/agent-offer")
  end

  def set_agent_answer(session_id, sdp_answer:, peer_id: nil)
    post("/sessions/#{session_id}/agent-answer", { sdp_answer: sdp_answer, peer_id: peer_id }.compact)
  end

  def change_peer_role(session_id, peer_id:, role:)
    patch("/sessions/#{session_id}/peers/#{peer_id}/role", { role: role })
  end

  def set_meta_answer(session_id, sdp_answer:)
    post("/sessions/#{session_id}/meta-answer", { sdp_answer: sdp_answer })
  end

  def reconnect_agent(session_id)
    post("/sessions/#{session_id}/agent-reconnect")
  end

  def terminate_session(session_id)
    post("/sessions/#{session_id}/terminate")
  end

  def create_runtime_agent(session_id, call_ref:, account_id:, conversation_id:, inbox_id:)
    post(
      "/sessions/#{session_id}/runtime-agent",
      {
        call_ref: call_ref,
        account_id: account_id&.to_s,
        conversation_id: conversation_id&.to_s,
        inbox_id: inbox_id&.to_s
      }.compact
    )
  end

  def download_recording(session_id, side: nil)
    path = "/sessions/#{session_id}/recording"
    path = "#{path}?side=#{side}" if side
    response = execute_request(:get, path)
    unless response.success?
      Rails.logger.error "[MEDIA SERVER] Recording download failed: side=#{side.inspect} status=#{response.code}"
      raise SessionError, "Recording download failed (#{response.code})"
    end
    response.body
  end

  def add_peer(session_id, role:, label:)
    post("/sessions/#{session_id}/peers", { role: role, label: label })
  end

  def remove_peer(session_id, peer_id:)
    delete("/sessions/#{session_id}/peers/#{peer_id}")
  end

  def inject_audio(session_id, file_path:, mode: 'replace', loop: false, target: 'peer_a')
    post("/sessions/#{session_id}/inject-audio", { source: file_path, mode: mode, loop: loop, target: target })
  end

  def stop_audio_injection(session_id, injection_id:)
    delete("/sessions/#{session_id}/inject-audio/#{injection_id}")
  end

  def health_check
    get('/health')
  end

  private

  def post(path, body = {})
    response = execute_request(:post, path, body)
    parse_response(response)
  end

  def get(path)
    response = execute_request(:get, path)
    parse_response(response)
  end

  def patch(path, body = {})
    response = execute_request(:patch, path, body)
    parse_response(response)
  end

  def delete(path)
    response = execute_request(:delete, path)
    parse_response(response)
  end

  def execute_request(method, path, body = nil)
    url = "#{base_url}#{path}"
    options = { headers: auth_headers, timeout: TIMEOUT }
    options[:body] = body.to_json if body.present?

    Rails.logger.info "[MEDIA SERVER] #{method.upcase} #{path}"
    HTTParty.send(method, url, options)
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    Rails.logger.error "[MEDIA SERVER] Connection failed: #{e.class} #{e.message}"
    raise ConnectionError, "Media server unavailable: #{e.message}"
  end

  def parse_response(response)
    unless response.success?
      parsed_body = parse_error_body(response)
      error_code = parsed_body['code'].presence || parsed_body['status'].presence
      Rails.logger.error "[MEDIA SERVER] Request failed: status=#{response.code} code=#{error_code.presence || 'unknown'} body=#{response.body}"
      raise SessionError.new(
        "Media server error (#{response.code}): #{response.body}",
        http_status: response.code,
        response_body: response.body,
        error_code: error_code
      )
    end

    response.parsed_response
  end

  def parse_error_body(response)
    body = response.parsed_response
    body.is_a?(Hash) ? body.stringify_keys : {}
  rescue StandardError
    {}
  end

  def base_url
    ENV.fetch('MEDIA_SERVER_URL', 'http://localhost:4000')
  end

  def auth_token
    token = ENV.fetch('MEDIA_SERVER_AUTH_TOKEN', '').to_s
    raise ConnectionError, 'MEDIA_SERVER_AUTH_TOKEN is required' if token.blank?

    token
  end

  def auth_headers
    {
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{auth_token}"
    }
  end

  # Go media server expects `urls` to always be an array of strings.
  # Accept legacy data that may have `urls` as a single string.
  def normalize_ice_servers(servers)
    return [] if servers.blank?

    Array(servers).map do |srv|
      s = srv.respond_to?(:to_h) ? srv.to_h.transform_keys(&:to_s) : srv.stringify_keys
      urls = s['urls']
      s['urls'] = urls.is_a?(Array) ? urls : Array(urls).compact
      s
    end
  end
end
