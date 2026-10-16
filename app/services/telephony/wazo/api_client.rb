# frozen_string_literal: true

require 'base64'
require 'cgi'
require 'json'
require 'uri'

class Telephony::Wazo::ApiClient # rubocop:disable Metrics/ClassLength -- explicit Wazo Confd, Calld, and Call-Logd resource surface
  TOKEN_PATH = '/api/auth/0.1/token'
  SIP_ENDPOINTS_PATH = '/api/confd/1.1/endpoints/sip'
  USERS_PATH = '/api/confd/1.1/users'
  LINES_PATH = '/api/confd/1.1/lines'
  EXTENSIONS_PATH = '/api/confd/1.1/extensions'
  TRUNKS_PATH = '/api/confd/1.1/trunks'
  REGISTRATIONS_SIP_PATH = '/api/confd/1.1/registrations/sip'
  CONTEXTS_PATH = '/api/confd/1.1/contexts'
  INCALLS_PATH = '/api/confd/1.1/incalls'
  OUTCALLS_PATH = '/api/confd/1.1/outcalls'
  CDR_PATH = '/api/call-logd/1.0/cdr'
  CALLS_PATH = '/api/calld/1.0/calls'
  TRANSFERS_PATH = '/api/calld/1.0/transfers'
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

  def cdr(from:, until_time:, limit: 100, offset: 0)
    request(:get, CDR_PATH, params: {
              from: from.iso8601, until: until_time.iso8601,
              limit: limit, offset: offset, order: 'asc'
            })
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

  # --- Confd Trunk, Context & Routing APIs ---

  def trunks
    payload = request(:get, TRUNKS_PATH, params: { limit: 1000 })
    Array.wrap(payload['items'])
  end

  def trunk(id)
    request(:get, "#{TRUNKS_PATH}/#{escape(id)}")
  end

  def create_trunk(payload)
    request(:post, TRUNKS_PATH, body: payload)
  end

  def update_trunk(id, payload)
    request(:put, "#{TRUNKS_PATH}/#{escape(id)}", body: payload)
  end

  def delete_trunk(id)
    delete_resource("#{TRUNKS_PATH}/#{escape(id)}")
  end

  def associate_trunk_sip_endpoint(trunk_id, endpoint_uuid)
    request(:put, "#{TRUNKS_PATH}/#{escape(trunk_id)}/endpoints/sip/#{escape(endpoint_uuid)}")
  end

  def associate_trunk_register_sip(trunk_id, register_uuid)
    request(:put, "#{TRUNKS_PATH}/#{escape(trunk_id)}/registers/sip/#{escape(register_uuid)}")
  end

  def sip_registrations
    payload = request(:get, REGISTRATIONS_SIP_PATH, params: { limit: 1000 })
    Array.wrap(payload['items'])
  end

  def create_sip_registration(payload)
    request(:post, REGISTRATIONS_SIP_PATH, body: payload)
  end

  def update_sip_registration(uuid, payload)
    request(:put, "#{REGISTRATIONS_SIP_PATH}/#{escape(uuid)}", body: payload)
  end

  def delete_sip_registration(uuid)
    delete_resource("#{REGISTRATIONS_SIP_PATH}/#{escape(uuid)}")
  end

  def contexts
    payload = request(:get, CONTEXTS_PATH, params: { limit: 1000 })
    Array.wrap(payload['items'])
  end

  def create_context(payload)
    request(:post, CONTEXTS_PATH, body: payload)
  end

  def update_context(id, payload)
    request(:put, "#{CONTEXTS_PATH}/#{escape(id)}", body: payload)
  end

  def associate_context_contexts(context_id, included_context_ids)
    request(:put, "#{CONTEXTS_PATH}/#{escape(context_id)}/contexts",
            body: { contexts: Array(included_context_ids).map { |cid| { id: cid } } })
  end

  def incalls
    payload = request(:get, INCALLS_PATH, params: { limit: 1000 })
    Array.wrap(payload['items'])
  end

  def create_incall(payload)
    request(:post, INCALLS_PATH, body: payload)
  end

  def update_incall(id, payload)
    request(:put, "#{INCALLS_PATH}/#{escape(id)}", body: payload)
  end

  def associate_incall_extension(incall_id, extension_id)
    request(:put, "#{INCALLS_PATH}/#{escape(incall_id)}/extensions/#{escape(extension_id)}")
  end

  def outcalls
    payload = request(:get, OUTCALLS_PATH, params: { limit: 1000 })
    Array.wrap(payload['items'])
  end

  def create_outcall(payload)
    request(:post, OUTCALLS_PATH, body: payload)
  end

  def update_outcall(id, payload)
    request(:put, "#{OUTCALLS_PATH}/#{escape(id)}", body: payload)
  end

  def associate_outcall_trunks(outcall_id, trunk_ids)
    request(:put, "#{OUTCALLS_PATH}/#{escape(outcall_id)}/trunks",
            body: { trunks: Array(trunk_ids).map { |tid| { id: tid } } })
  end

  def associate_outcall_extension(outcall_id, extension_id, payload = {})
    request(:put, "#{OUTCALLS_PATH}/#{escape(outcall_id)}/extensions/#{escape(extension_id)}", body: payload)
  end

  # --- Calld Active Calls, Recording & Transfer APIs ---

  def active_calls(recurse: false)
    payload = request(:get, CALLS_PATH, params: { recurse: recurse })
    Array.wrap(payload['items'])
  end

  def active_call(call_id)
    request(:get, "#{CALLS_PATH}/#{escape(call_id)}")
  end

  def hangup_call(call_id)
    delete_resource("#{CALLS_PATH}/#{escape(call_id)}")
  end

  def start_call_recording(call_id)
    request(:put, "#{CALLS_PATH}/#{escape(call_id)}/record/start")
  end

  def stop_call_recording(call_id)
    request(:put, "#{CALLS_PATH}/#{escape(call_id)}/record/stop")
  end

  def pause_call_recording(call_id)
    request(:put, "#{CALLS_PATH}/#{escape(call_id)}/record/pause")
  end

  def resume_call_recording(call_id)
    request(:put, "#{CALLS_PATH}/#{escape(call_id)}/record/resume")
  end

  def connect_call_to_user(call_id, user_uuid, timeout: 30)
    request(:put, "#{CALLS_PATH}/#{escape(call_id)}/user/#{escape(user_uuid)}", body: { timeout: timeout })
  end

  def initiate_transfer(transferred_call:, initiator_call:, context:, exten:, flow: 'blind', variables: {}, timeout: nil)
    body = {
      transferred_call: transferred_call.to_s,
      initiator_call: initiator_call.to_s,
      context: context.to_s,
      exten: exten.to_s,
      flow: flow.to_s
    }
    body[:variables] = variables if variables.present?
    body[:timeout] = timeout if timeout.present?
    request(:post, TRANSFERS_PATH, body: body)
  end

  def complete_transfer(transfer_id)
    request(:put, "#{TRANSFERS_PATH}/#{escape(transfer_id)}/complete")
  end

  def cancel_transfer(transfer_id)
    delete_resource("#{TRANSFERS_PATH}/#{escape(transfer_id)}")
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
