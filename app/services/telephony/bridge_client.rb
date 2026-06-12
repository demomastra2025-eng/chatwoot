class Telephony::BridgeClient
  DEFAULT_TIMEOUT_SECONDS = 10
  WRITE_BODY_METHODS = %i[post put patch].freeze

  def initialize(base_url: ENV.fetch('TELEPHONY_BRIDGE_BASE_URL', ''), secret: ENV.fetch('TELEPHONY_BRIDGE_SHARED_SECRET', ''), account_id: nil,
                 request_id: Current.request_id, debug_log_path: Telephony::DebugLogger.default_log_path)
    @base_url = base_url.to_s
    @secret = secret.to_s
    @account_id = account_id.presence
    @request_id = request_id.presence
    @debug_log_path = debug_log_path.to_s
  end

  def get(path, query: {}, idempotency_key: nil)
    perform_request(:get, path, query: query, idempotency_key: idempotency_key)
  end

  def post(path, payload = {}, idempotency_key: nil)
    perform_request(:post, path, payload: payload, idempotency_key: idempotency_key)
  end

  def put(path, payload = {}, idempotency_key: nil)
    perform_request(:put, path, payload: payload, idempotency_key: idempotency_key)
  end

  def patch(path, payload = {}, idempotency_key: nil)
    perform_request(:patch, path, payload: payload, idempotency_key: idempotency_key)
  end

  def delete(path, payload = nil, query: {}, idempotency_key: nil)
    perform_request(:delete, path, query: query, payload: payload, idempotency_key: idempotency_key)
  end

  private

  attr_reader :account_id, :base_url, :debug_log_path, :request_id, :secret

  def perform_request(method, path, query: nil, payload: nil, idempotency_key: nil)
    if base_url.blank?
      raise Telephony::Error.new(code: 'BRIDGE_NOT_CONFIGURED', message: 'Telephony bridge is not configured',
                                 status: :service_unavailable)
    end

    url = URI.join(normalized_base_url, normalized_path(path)).to_s
    options = {
      headers: request_headers(idempotency_key: idempotency_key),
      timeout: DEFAULT_TIMEOUT_SECONDS
    }
    options[:query] = query if query.present?
    options[:body] = payload.to_json if request_body_required?(method, payload)

    log_debug_request(method, path, url, payload)
    response = HTTParty.public_send(method, url, options)
    log_debug_response(method, path, response)
    handle_response(response, method: method, path: path)
  rescue SocketError, EOFError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
         Net::OpenTimeout, Net::ReadTimeout, Net::HTTPBadResponse, Net::ProtocolError,
         OpenSSL::SSL::SSLError, Timeout::Error, HTTParty::Error => e
    log_debug_event(
      event: 'telephony_bridge_debug_network_error',
      method: method.to_s.upcase,
      path: path,
      url: url,
      account_id: account_id,
      request_id: request_id,
      error_class: e.class.name,
      error_message: e.message
    )

    raise Telephony::Error.new(
      code: 'BRIDGE_UNAVAILABLE',
      message: "Telephony bridge request failed: #{e.message}",
      status: :bad_gateway
    )
  end

  def request_body_required?(method, payload)
    payload.present? || WRITE_BODY_METHODS.include?(method.to_sym)
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

  def request_headers(idempotency_key: nil)
    headers = {
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    }
    headers['X-Bridge-Secret'] = secret if secret.present?
    headers['X-Account-Id'] = account_id.to_s if account_id.present?
    headers['X-Request-Id'] = request_id if request_id.present?
    headers['X-Idempotency-Key'] = idempotency_key if idempotency_key.present?
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

  def log_debug_request(method, path, url, payload)
    return unless debug_logging_enabled?(method, path)

    log_debug_event(
      event: 'telephony_bridge_debug_request',
      method: method.to_s.upcase,
      path: path,
      url: url,
      account_id: account_id,
      request_id: request_id,
      payload: payload
    )
  end

  def log_debug_response(method, path, response)
    return unless debug_logging_enabled?(method, path)

    log_debug_event(
      event: 'telephony_bridge_debug_response',
      method: method.to_s.upcase,
      path: path,
      account_id: account_id,
      request_id: request_id,
      status: response.code.to_i,
      body: parsed_response(response)
    )
  end

  def debug_logging_enabled?(method, path)
    Telephony::DebugLogger.enabled? && method.to_sym == :post && path.to_s == '/telephony/calls/outbound'
  end

  def log_debug_event(event)
    Telephony::DebugLogger.log(event: event.delete(:event), payload: event, log_path: debug_log_path)
  end
end
