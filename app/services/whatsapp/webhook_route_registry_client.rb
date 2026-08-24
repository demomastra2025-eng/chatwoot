require 'net/http'
require 'openssl'
require 'uri'

class Whatsapp::WebhookRouteRegistryClient
  CANONICAL_URL = 'https://app.one-link.kz/internal/whatsapp/webhook_routes'.freeze
  URL_ENV_KEY = 'WHATSAPP_WEBHOOK_ROUTE_REGISTRY_URL'.freeze
  SECRET_ENV_KEY = 'WHATSAPP_WEBHOOK_ROUTE_REGISTRY_SECRET'.freeze
  DESTINATION_CONFIG_KEY = 'WHATSAPP_WEBHOOK_RECEIVER_DESTINATION'.freeze
  DESTINATIONS = %w[dev widget].freeze
  DIGITS = /\A\d+\z/
  REQUEST_TIMEOUT = 5
  DEFAULT_VALUE = Object.new.freeze
  REGISTRATION_TOKEN_HEADER = 'X-OneLink-Route-Registration-Token'.freeze
  REGISTRATION_TOKEN = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  class Error < StandardError; end
  Registration = Data.define(:status, :token) do
    def created? = status == :created
  end

  def self.signature(secret:, method:, destination:, timestamp:, body:)
    signed_payload = [method.to_s.upcase, destination, timestamp, body].join("\n")
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, signed_payload)}"
  end

  def initialize(url: DEFAULT_VALUE, secret: DEFAULT_VALUE, destination: DEFAULT_VALUE, http_class: Net::HTTP)
    @url_injected = !url.equal?(DEFAULT_VALUE)
    @url = url.equal?(DEFAULT_VALUE) ? ENV[URL_ENV_KEY].to_s : url.to_s
    @secret = secret.equal?(DEFAULT_VALUE) ? ENV[SECRET_ENV_KEY].to_s : secret.to_s
    @destination = if destination.equal?(DEFAULT_VALUE)
                     GlobalConfigService.load(DESTINATION_CONFIG_KEY, nil).to_s
                   else
                     destination.to_s
                   end
    @http_class = http_class
  end

  def configured?
    @secret.present? && DESTINATIONS.include?(@destination) && valid_url?
  end

  def register!(waba_id:, phone_number_id:)
    request_route(:put, waba_id: waba_id, phone_number_id: phone_number_id)
  end

  def unregister!(waba_id:, phone_number_id:, registration_token: nil)
    request_route(:delete, waba_id: waba_id, phone_number_id: phone_number_id, registration_token: registration_token)
  end

  private

  def request_route(method, waba_id:, phone_number_id:, registration_token: nil)
    return false unless configured?

    validate_identifier!(waba_id)
    validate_identifier!(phone_number_id)
    body = route_body(waba_id, phone_number_id, registration_token)
    response = perform_request(method, body)
    if response.is_a?(Net::HTTPSuccess)
      return registration_from(response) if method == :put

      return true
    end

    raise Error, "WhatsApp webhook route registry returned status=#{response.code}"
  rescue Error
    raise
  rescue StandardError => e
    raise Error, "WhatsApp webhook route registry request failed error_class=#{e.class.name}"
  end

  def registration_from(response)
    token = response[REGISTRATION_TOKEN_HEADER].to_s.presence
    status = response.code.to_i == 201 && token&.match?(REGISTRATION_TOKEN) ? :created : :existing
    Registration.new(status: status, token: token)
  end

  def route_body(waba_id, phone_number_id, registration_token)
    validate_registration_token!(registration_token) if registration_token
    payload = { waba_id: waba_id.to_s, phone_number_id: phone_number_id.to_s, destination: @destination }
    payload[:registration_token] = registration_token if registration_token
    JSON.generate(payload)
  end

  def perform_request(method, body)
    uri = URI.parse(@url)
    build_http(uri).request(build_request(method, uri, body))
  end

  def build_http(uri)
    http = @http_class.new(uri.host, uri.port, nil)
    http.use_ssl = uri.is_a?(URI::HTTPS)
    http.open_timeout = REQUEST_TIMEOUT
    http.read_timeout = REQUEST_TIMEOUT
    http.write_timeout = REQUEST_TIMEOUT
    http
  end

  def build_request(method, uri, body)
    timestamp = Time.now.to_i.to_s
    request = method == :put ? Net::HTTP::Put.new(uri.request_uri) : Net::HTTP::Delete.new(uri.request_uri)
    request['Content-Type'] = 'application/json'
    request['X-OneLink-Route-Timestamp'] = timestamp
    request['X-OneLink-Route-Signature'] = request_signature(method, timestamp, body)
    request.body = body
    request
  end

  def request_signature(method, timestamp, body)
    self.class.signature(
      secret: @secret,
      method: method,
      destination: @destination,
      timestamp: timestamp,
      body: body
    )
  end

  def valid_url?
    return true if @url == CANONICAL_URL
    return false unless @url_injected

    uri = URI.parse(@url)
    local_http_url?(uri) && exact_route_path?(uri)
  rescue URI::InvalidURIError
    false
  end

  def local_http_url?(uri)
    %w[localhost 127.0.0.1 ::1].include?(uri.hostname) && uri.is_a?(URI::HTTP)
  end

  def exact_route_path?(uri)
    uri.path == URI.parse(CANONICAL_URL).path &&
      uri.userinfo.blank? && uri.query.blank? && uri.fragment.blank?
  end

  def validate_identifier!(identifier)
    raise Error, 'WhatsApp webhook route identifiers must contain digits only' unless identifier.to_s.match?(DIGITS)
  end

  def validate_registration_token!(registration_token)
    return if registration_token.to_s.match?(REGISTRATION_TOKEN)

    raise Error, 'WhatsApp webhook route registration token is invalid'
  end
end
