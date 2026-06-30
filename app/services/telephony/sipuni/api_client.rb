# frozen_string_literal: true

require 'digest'

class Telephony::Sipuni::ApiClient
  DEFAULT_BASE_URL = 'https://sipuni.com'
  DEFAULT_TIMEOUT_SECONDS = 5
  NETWORK_ERRORS = [
    SocketError,
    EOFError,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    Net::HTTPBadResponse,
    Net::ProtocolError,
    OpenSSL::SSL::SSLError,
    Timeout::Error,
    HTTParty::Error
  ].freeze

  def initialize(
    user: ENV.fetch('SIPUNI_INTEGRATION_USER', ''),
    secret: ENV.fetch('SIPUNI_INTEGRATION_SECRET', ''),
    base_url: ENV.fetch('SIPUNI_API_BASE_URL', DEFAULT_BASE_URL),
    timeout: ENV.fetch('SIPUNI_API_TIMEOUT_SECONDS', DEFAULT_TIMEOUT_SECONDS)
  )
    @user = user.to_s.strip
    @secret = secret.to_s
    @base_url = base_url.to_s.strip.presence || DEFAULT_BASE_URL
    @timeout = positive_integer(timeout, DEFAULT_TIMEOUT_SECONDS)
  end

  def configured?
    user.present? && secret.present?
  end

  def hangup(call_id:)
    raise_not_configured! unless configured?

    normalized_call_id = call_id.to_s.strip
    if normalized_call_id.blank?
      raise Telephony::Error.new(
        code: 'SIPUNI_CALL_ID_REQUIRED',
        message: 'Sipuni callId is required',
        status: :unprocessable_content
      )
    end

    response = HTTParty.post(
      endpoint('/api/events/call/hangup'),
      body: hangup_payload(normalized_call_id),
      headers: request_headers,
      timeout: timeout
    )
    handle_response(response)
  rescue *NETWORK_ERRORS => e
    raise Telephony::Error.new(
      code: 'SIPUNI_UNAVAILABLE',
      message: "Sipuni API request failed: #{e.message}",
      status: :bad_gateway
    )
  end

  private

  attr_reader :base_url, :secret, :timeout, :user

  def hangup_payload(call_id)
    {
      user: user,
      callId: call_id,
      hash: Digest::MD5.hexdigest([call_id, user, secret].join('+'))
    }
  end

  def request_headers
    {
      'Accept' => 'application/json, text/plain, */*',
      'Content-Type' => 'application/x-www-form-urlencoded'
    }
  end

  def handle_response(response)
    parsed = parsed_response(response)
    return parsed if response.success?

    raise Telephony::Error.new(
      code: 'SIPUNI_REQUEST_FAILED',
      message: "Sipuni API request failed: HTTP #{response.code} #{response.body}",
      status: :bad_gateway,
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

  def endpoint(path)
    URI.join(normalized_base_url, path.to_s.delete_prefix('/')).to_s
  end

  def normalized_base_url
    base_url.ends_with?('/') ? base_url : "#{base_url}/"
  end

  def positive_integer(value, fallback)
    integer = value.to_i
    integer.positive? ? integer : fallback
  end

  def raise_not_configured!
    raise Telephony::Error.new(
      code: 'SIPUNI_API_NOT_CONFIGURED',
      message: 'Sipuni integration user and secret are required',
      status: :service_unavailable
    )
  end
end
