class Whatsapp::AiVoiceRuntimeClient
  class ConnectionError < StandardError; end

  class AttachError < StandardError
    attr_reader :http_status, :response_body

    def initialize(message, http_status: nil, response_body: nil)
      super(message)
      @http_status = http_status
      @response_body = response_body
    end
  end

  TIMEOUT = 5
  DEFAULT_ATTACH_PATH = '/internal/whatsapp-cloud/calls'.freeze
  DEFAULT_PREFLIGHT_PATH = '/internal/whatsapp-cloud/preflight'.freeze

  def preflight_call(payload)
    request(preflight_url, payload, operation: 'Preflight')
  end

  def attach_call(payload)
    request(attach_url, payload, operation: 'Attach')
  end

  def enabled?
    base_url.present? && auth_token_value.present?
  end

  private

  def request(url, payload, operation:)
    response = HTTParty.post(
      url,
      headers: auth_headers,
      body: normalize_payload(payload).to_json,
      timeout: TIMEOUT
    )
    parse_response(response, operation: operation)
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    Rails.logger.error "[WHATSAPP AI VOICE RUNTIME] #{operation} connection failed: #{e.class} #{e.message}"
    raise ConnectionError, "AI voice runtime unavailable: #{e.message}"
  end

  def parse_response(response, operation:)
    unless response.success?
      Rails.logger.error "[WHATSAPP AI VOICE RUNTIME] #{operation} failed: status=#{response.code} body=#{response.body}"
      raise AttachError.new(
        "AI voice runtime #{operation.downcase} failed (#{response.code})",
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

  def preflight_url
    "#{required_base_url}#{preflight_path}"
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
    path = ENV.fetch('ONELINK_AI_VOICE_WHATSAPP_ATTACH_PATH', ENV.fetch('AI_VOICE_WHATSAPP_ATTACH_PATH', DEFAULT_ATTACH_PATH)).to_s
    path.start_with?('/') ? path : "/#{path}"
  end

  def preflight_path
    default_path = attach_path == DEFAULT_ATTACH_PATH ? DEFAULT_PREFLIGHT_PATH : "#{attach_path.sub(%r{/+\z}, '')}/preflight"
    path = ENV.fetch('ONELINK_AI_VOICE_WHATSAPP_PREFLIGHT_PATH', default_path).to_s
    path.start_with?('/') ? path : "/#{path}"
  end

  def auth_token
    token = auth_token_value
    raise ConnectionError, 'ONELINK_AI_VOICE_INTERNAL_TOKEN or AI_VOICE_INTERNAL_TOKEN internal token is required' if token.blank?

    token
  end

  def auth_token_value
    @auth_token_value ||= ENV.fetch('ONELINK_AI_VOICE_INTERNAL_TOKEN', ENV.fetch('AI_VOICE_INTERNAL_TOKEN', '')).to_s
  end

  def auth_headers
    {
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{auth_token}"
    }
  end

  def normalize_payload(payload)
    normalized = payload.deep_stringify_keys
    %w[account_id inbox_id conversation_id whatsapp_call_id call_session_id].each do |key|
      normalized[key] = normalized[key].to_s if normalized[key].present?
    end
    normalized
  end
end
