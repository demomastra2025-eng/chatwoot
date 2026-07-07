class Telephony::AiVoice::JanusSipRuntimeClient
  class ConnectionError < StandardError; end

  class AttachError < StandardError
    attr_reader :http_status, :response_body

    def initialize(message, http_status: nil, response_body: nil)
      super(message)
      @http_status = http_status
      @response_body = response_body
    end
  end

  TIMEOUT = 3
  DEFAULT_ATTACH_PATH = '/internal/janus-sip/calls'.freeze

  def attach_call(payload)
    response = HTTParty.post(
      attach_url,
      headers: auth_headers,
      body: normalize_payload(payload).to_json,
      timeout: TIMEOUT
    )
    parse_response(response)
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    Rails.logger.error "[JANUS SIP AI VOICE RUNTIME] Attach connection failed: #{e.class} #{e.message}"
    raise ConnectionError, "AI voice runtime unavailable: #{e.message}"
  end

  def enabled?
    base_url.present? && auth_token_value.present?
  end

  private

  def parse_response(response)
    unless response.success?
      Rails.logger.error "[JANUS SIP AI VOICE RUNTIME] Attach failed: status=#{response.code} body=#{response.body}"
      raise AttachError.new(
        "AI voice runtime attach failed (#{response.code})",
        http_status: response.code,
        response_body: response.body
      )
    end

    parsed = response.parsed_response
    parsed.is_a?(Hash) ? parsed : {}
  end

  def attach_url
    "#{required_base_url}#{attach_path}"
  end

  def required_base_url
    url = base_url
    raise ConnectionError, 'ONELINK_AI_VOICE_BASE_URL or AI_VOICE_BASE_URL base URL is required' if url.blank?

    url
  end

  def base_url
    @base_url ||= ENV.fetch('ONELINK_AI_VOICE_BASE_URL', ENV.fetch('AI_VOICE_BASE_URL', '')).to_s.sub(%r{/+\z}, '')
  end

  def attach_path
    path = ENV.fetch(
      'ONELINK_AI_VOICE_JANUS_ATTACH_PATH',
      ENV.fetch('AI_VOICE_JANUS_ATTACH_PATH', ENV.fetch('VOICE_AGENT_JANUS_ATTACH_PATH', DEFAULT_ATTACH_PATH))
    ).to_s
    path.start_with?('/') ? path : "/#{path}"
  end

  def auth_token
    token = auth_token_value
    if token.blank?
      raise ConnectionError,
            'ONELINK_AI_VOICE_INTERNAL_TOKEN, AI_VOICE_INTERNAL_TOKEN, or compatible voice runtime internal token is required'
    end

    token
  end

  def auth_token_value
    @auth_token_value ||= first_env_value(
      'ONELINK_AI_VOICE_INTERNAL_TOKEN',
      'AI_VOICE_INTERNAL_TOKEN',
      'VOICE_AGENT_ONELINK_AI_SHARED_SECRET',
      'VOICE_AGENT_INTERNAL_TOKEN',
      'ONELINK_INTERNAL_SECRET',
      'ONELINK_INTERNAL_TOKEN'
    ).to_s
  end

  def auth_headers
    {
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{auth_token}"
    }
  end

  def normalize_payload(payload)
    normalized = payload.deep_stringify_keys
    %w[account_id inbox_id conversation_id call_session_id sip_profile_id number_binding_id].each do |key|
      normalized[key] = normalized[key].to_s if normalized[key].present?
    end
    normalized
  end

  def first_env_value(*keys)
    keys.lazy.map { |key| ENV.fetch(key, nil).presence }.find(&:present?)
  end
end
