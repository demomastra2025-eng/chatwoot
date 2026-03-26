class Telephony::BridgeClient
  DEFAULT_TIMEOUT_SECONDS = 10

  def initialize(base_url: ENV.fetch('TELEPHONY_BRIDGE_BASE_URL', ''), secret: ENV.fetch('TELEPHONY_BRIDGE_SHARED_SECRET', ''))
    @base_url = base_url.to_s
    @secret = secret.to_s
  end

  def get(path, query: {})
    perform_request(:get, path, query: query)
  end

  def post(path, payload = {})
    perform_request(:post, path, payload: payload)
  end

  private

  attr_reader :base_url, :secret

  def perform_request(method, path, query: nil, payload: nil)
    raise Telephony::Error.new(code: 'BRIDGE_NOT_CONFIGURED', message: 'Telephony bridge is not configured', status: :service_unavailable) if base_url.blank?

    url = URI.join(normalized_base_url, normalized_path(path)).to_s
    options = {
      headers: request_headers,
      timeout: DEFAULT_TIMEOUT_SECONDS
    }
    options[:query] = query if query.present?
    options[:body] = payload.to_json if payload.present? || method == :post

    response = HTTParty.public_send(method, url, options)
    handle_response(response, method: method, path: path)
  rescue SocketError, EOFError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
         Net::OpenTimeout, Net::ReadTimeout, Net::HTTPBadResponse, Net::ProtocolError,
         OpenSSL::SSL::SSLError, Timeout::Error, HTTParty::Error => e
    raise Telephony::Error.new(
      code: 'BRIDGE_UNAVAILABLE',
      message: "Telephony bridge request failed: #{e.message}",
      status: :bad_gateway
    )
  end

  def handle_response(response, method:, path:)
    parsed = parsed_response(response)
    return parsed if response.success?

    message = if parsed.is_a?(Hash)
                parsed['error'] || parsed['message'] || response.body.to_s
              else
                response.body.to_s
              end

    raise Telephony::Error.new(
      code: 'BRIDGE_REQUEST_FAILED',
      message: "Telephony bridge #{method.to_s.upcase} #{path} failed: HTTP #{response.code} #{message}",
      status: bridge_status(response.code),
      details: parsed
    )
  end

  def parsed_response(response)
    body = response.body.to_s
    return {} if body.blank?

    response.parsed_response
  rescue JSON::ParserError, TypeError
    body
  end

  def request_headers
    headers = {
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    }
    headers['X-Bridge-Secret'] = secret if secret.present?
    headers
  end

  def normalized_base_url
    base_url.ends_with?('/') ? base_url : "#{base_url}/"
  end

  def normalized_path(path)
    path.to_s.delete_prefix('/')
  end

  def bridge_status(code)
    return :not_found if code.to_i == 404
    return :unauthorized if code.to_i == 401

    :bad_gateway
  end
end
