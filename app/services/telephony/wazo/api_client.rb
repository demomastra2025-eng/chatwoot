# frozen_string_literal: true

require 'base64'
require 'cgi'
require 'json'
require 'uri'

class Telephony::Wazo::ApiClient # rubocop:disable Metrics/ClassLength -- explicit Wazo Confd resource surface
  TOKEN_PATH = '/api/auth/0.1/token'
  SIP_ENDPOINTS_PATH = '/api/confd/1.1/endpoints/sip'
  USERS_PATH = '/api/confd/1.1/users'
  LINES_PATH = '/api/confd/1.1/lines'
  EXTENSIONS_PATH = '/api/confd/1.1/extensions'
  REQUEST_TIMEOUT = 15

  def self.configured?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('TELEPHONY_WAZO_PROVISIONING_ENABLED', nil)) &&
      %w[
        TELEPHONY_WAZO_API_URL TELEPHONY_WAZO_API_USERNAME TELEPHONY_WAZO_API_PASSWORD
        TELEPHONY_WAZO_TENANT_UUID TELEPHONY_WAZO_SIP_HOST TELEPHONY_WAZO_SIP_CONTEXT
      ].all? { |key| ENV[key].present? }
  end

  def initialize(
    base_url: ENV.fetch('TELEPHONY_WAZO_API_URL', nil),
    username: ENV.fetch('TELEPHONY_WAZO_API_USERNAME', nil),
    password: ENV.fetch('TELEPHONY_WAZO_API_PASSWORD', nil),
    tenant_uuid: ENV.fetch('TELEPHONY_WAZO_TENANT_UUID', nil),
    ca_file: ENV.fetch('TELEPHONY_WAZO_CA_FILE', nil)
  )
    @username = username.to_s
    @password = password.to_s
    @tenant_uuid = tenant_uuid.presence
    @ca_file = ca_file.presence
    ensure_credentials_configured!(base_url)
    @base_url = normalized_base_url(base_url)
  end

  def sip_endpoints
    payload = request(:get, SIP_ENDPOINTS_PATH, params: { limit: 1000 })
    Array.wrap(payload['items'])
  end

  def create_sip_endpoint(payload)
    request(:post, SIP_ENDPOINTS_PATH, body: payload)
  end

  def sip_endpoint(uuid)
    request(:get, "#{SIP_ENDPOINTS_PATH}/#{escape(uuid)}")
  end

  def update_sip_endpoint(uuid, payload)
    request(:put, "#{SIP_ENDPOINTS_PATH}/#{CGI.escapeURIComponent(uuid.to_s)}", body: payload)
  end

  def delete_sip_endpoint(uuid)
    delete_resource("#{SIP_ENDPOINTS_PATH}/#{escape(uuid)}")
  end

  def create_user(payload)
    request(:post, USERS_PATH, body: payload)
  end

  def users
    payload = request(:get, USERS_PATH, params: { limit: 1000 })
    Array.wrap(payload['items'])
  end

  def update_user(uuid, payload)
    request(:put, "#{USERS_PATH}/#{escape(uuid)}", body: payload)
  end

  def user(uuid)
    request(:get, "#{USERS_PATH}/#{escape(uuid)}")
  end

  def delete_user(uuid)
    delete_resource("#{USERS_PATH}/#{escape(uuid)}")
  end

  def create_line(payload)
    request(:post, LINES_PATH, body: payload)
  end

  def lines
    payload = request(:get, LINES_PATH, params: { limit: 1000 })
    Array.wrap(payload['items'])
  end

  def line(id)
    request(:get, "#{LINES_PATH}/#{escape(id)}")
  end

  def update_line(id, payload)
    request(:put, "#{LINES_PATH}/#{escape(id)}", body: payload)
  end

  def delete_line(id)
    delete_resource("#{LINES_PATH}/#{escape(id)}")
  end

  def create_extension(payload)
    request(:post, EXTENSIONS_PATH, body: payload)
  end

  def extensions
    payload = request(:get, EXTENSIONS_PATH, params: { limit: 1000 })
    Array.wrap(payload['items'])
  end

  def update_extension(id, payload)
    request(:put, "#{EXTENSIONS_PATH}/#{escape(id)}", body: payload)
  end

  def extension(id)
    request(:get, "#{EXTENSIONS_PATH}/#{escape(id)}")
  end

  def delete_extension(id)
    delete_resource("#{EXTENSIONS_PATH}/#{escape(id)}")
  end

  def associate_user_line(user_uuid, line_id)
    request(:put, "#{USERS_PATH}/#{escape(user_uuid)}/lines/#{escape(line_id)}")
  end

  def associate_line_extension(line_id, extension_id)
    request(:put, "#{LINES_PATH}/#{escape(line_id)}/extensions/#{escape(extension_id)}")
  end

  def associate_line_sip_endpoint(line_id, endpoint_uuid)
    request(:put, "#{LINES_PATH}/#{escape(line_id)}/endpoints/sip/#{escape(endpoint_uuid)}")
  end

  def dissociate_user_line(user_uuid, line_id)
    delete_resource("#{USERS_PATH}/#{escape(user_uuid)}/lines/#{escape(line_id)}")
  end

  def dissociate_line_extension(line_id, extension_id)
    delete_resource("#{LINES_PATH}/#{escape(line_id)}/extensions/#{escape(extension_id)}")
  end

  def dissociate_line_sip_endpoint(line_id, endpoint_uuid)
    delete_resource("#{LINES_PATH}/#{escape(line_id)}/endpoints/sip/#{escape(endpoint_uuid)}")
  end

  private

  def escape(value)
    CGI.escapeURIComponent(value.to_s)
  end

  def delete_resource(path)
    request(:delete, path)
  rescue Telephony::Error => e
    raise unless e.details.to_h[:http_status] == 404

    {}
  end

  attr_reader :base_url, :username, :password, :tenant_uuid, :ca_file

  def request(method, path, body: nil, params: nil, auth_retry: true)
    response = perform_request(method, path, body: body, params: params)
    return parsed_body(response) if response.success?

    if response.status == 401 && auth_retry
      @auth_token = nil
      return request(method, path, body: body, params: params, auth_retry: false)
    end

    raise_request_error!(response)
  rescue Faraday::Error, JSON::ParserError => e
    raise Telephony::Error.new(
      code: 'WAZO_API_UNAVAILABLE',
      message: "Wazo API request failed: #{e.class.name}",
      status: :bad_gateway
    )
  end

  def perform_request(method, path, body:, params:)
    connection.public_send(method, path) do |request|
      configure_request(request, path, body, params)
    end
  end

  def configure_request(request, path, body, params)
    request.params.update(params) if params.present?
    request.headers['Accept'] = 'application/json'
    request.headers['Content-Type'] = 'application/json' if body.present?
    request.headers['X-Auth-Token'] = auth_token unless path == TOKEN_PATH
    request.headers['Wazo-Tenant'] = tenant_uuid if tenant_uuid.present?
    request.body = JSON.generate(body) if body.present?
    request.options.timeout = REQUEST_TIMEOUT
    request.options.open_timeout = REQUEST_TIMEOUT
  end

  def auth_token
    @auth_token ||= begin
      response = connection.post(TOKEN_PATH) do |request|
        request.headers['Accept'] = 'application/json'
        request.headers['Content-Type'] = 'application/json'
        request.headers['Authorization'] = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
        request.body = JSON.generate(expiration: 300)
        request.options.timeout = REQUEST_TIMEOUT
        request.options.open_timeout = REQUEST_TIMEOUT
      end
      raise_request_error!(response) unless response.success?

      parsed_body(response).dig('data', 'token').presence ||
        raise(Telephony::Error.new(code: 'WAZO_AUTH_TOKEN_MISSING', message: 'Wazo API did not return an auth token', status: :bad_gateway))
    end
  end

  def connection
    @connection ||= Faraday.new(url: base_url, ssl: ssl_options)
  end

  def ssl_options
    return {} if ca_file.blank?

    { ca_file: ca_file }
  end

  def parsed_body(response)
    return {} if response.body.blank?

    JSON.parse(response.body)
  end

  def raise_request_error!(response)
    code = {
      401 => 'WAZO_AUTH_FAILED',
      403 => 'WAZO_TENANT_FORBIDDEN',
      404 => 'WAZO_RESOURCE_NOT_FOUND',
      409 => 'WAZO_RESOURCE_CONFLICT',
      422 => 'WAZO_VALIDATION_FAILED',
      429 => 'WAZO_RATE_LIMITED'
    }.fetch(response.status, response.status >= 500 ? 'WAZO_API_UNAVAILABLE' : 'WAZO_API_REQUEST_FAILED')
    raise Telephony::Error.new(
      code: code,
      message: "Wazo API request failed with HTTP #{response.status}",
      status: :bad_gateway,
      details: { http_status: response.status }
    )
  end

  def normalized_base_url(value)
    uri = URI.parse(value.to_s)
    unless valid_https_origin?(uri)
      raise Telephony::Error.new(code: 'WAZO_API_URL_INVALID', message: 'Wazo API URL must be an HTTPS origin', status: :unprocessable_content)
    end

    "#{uri.scheme}://#{uri.host}#{uri.port == 443 ? '' : ":#{uri.port}"}"
  rescue URI::InvalidURIError
    raise Telephony::Error.new(code: 'WAZO_API_URL_INVALID', message: 'Wazo API URL must be an HTTPS origin', status: :unprocessable_content)
  end

  def valid_https_origin?(uri)
    uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.blank? && uri.query.blank? && uri.fragment.blank?
  end

  def ensure_credentials_configured!(raw_base_url)
    return if raw_base_url.present? && username.present? && password.present?

    raise Telephony::Error.new(code: 'WAZO_API_NOT_CONFIGURED', message: 'Wazo API credentials are not configured', status: :service_unavailable)
  end
end
