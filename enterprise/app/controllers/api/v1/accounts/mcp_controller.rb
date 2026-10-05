# frozen_string_literal: true

require 'uri'

require Rails.root.join('enterprise/lib/onelink/mcp/access_policy').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/auth_context').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/captain_tool_adapter').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/openapi_catalog').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/resource_catalog').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/server').to_s

class Api::V1::Accounts::McpController < Api::V1::Accounts::BaseController
  skip_before_action :current_account

  prepend_before_action :normalize_bearer_access_token_header
  before_action :set_mcp_current_account!
  before_action :ensure_mcp_user_access_token!
  before_action :ensure_mcp_origin!

  def process_action(*args, &block)
    if action_name == 'handle' && request.post? && json_content_type?
      raw_body = request.raw_post.to_s
      JSON.parse(raw_body) if raw_body.present?
    end

    super(*args, &block)
  rescue JSON::ParserError, ActionDispatch::Http::Parameters::ParseError
    render_early_json_parse_error
  end
  private :process_action

  def handle
    return method_not_allowed if request.get? || request.head?

    unless json_content_type?
      return render_jsonrpc_error(-32_600, 'Content-Type must be application/json', status: :unsupported_media_type)
    end

    unless valid_mcp_accept_header?
      return render_jsonrpc_error(
        -32_600,
        'Accept must allow application/json or text/event-stream',
        status: :not_acceptable
      )
    end

    payload = parsed_jsonrpc_payload
    response_payload = mcp_server.call(payload, transport_version: request_protocol_version)
    return head :accepted if response_payload.nil?

    render_mcp_payload(response_payload)
  rescue JSON::ParserError
    render_jsonrpc_error(-32_700, 'Parse error', status: :bad_request)
  rescue ActiveRecord::RecordNotFound
    render_jsonrpc_error(-32_602, 'Resource not found', status: :not_found)
  rescue Onelink::Mcp::Server::JsonRpcError => e
    render_jsonrpc_error(e.code, e.message, data: e.data, status: http_status_for_jsonrpc_error(e.code))
  rescue StandardError => e
    Rails.logger.error("MCP request failed: #{e.class}")
    render_jsonrpc_error(-32_603, 'Internal MCP server error', status: :internal_server_error)
  end

  def metadata
    render_endpoint_metadata
  end

  private

  def normalize_bearer_access_token_header
    return if request.headers[:api_access_token].present? || request.headers[:HTTP_API_ACCESS_TOKEN].present?

    token = bearer_token
    return if token.blank?

    request.headers[:api_access_token] = token
    request.headers[:HTTP_API_ACCESS_TOKEN] = token
  end

  def bearer_token
    authorization = request.headers['Authorization'].to_s
    match = authorization.match(/\ABearer\s+(.+)\z/i)
    match && match[1].to_s.strip
  end

  def set_mcp_current_account!
    account = Account.find(request.path_parameters[:account_id])
    return render_unauthorized('Account is suspended') unless account.active?

    account_user = account.account_users.find_by(user_id: Current.user&.id)
    return render_unauthorized('You are not authorized to access this account') if account_user.blank?

    Current.account = account
    Current.account_user = account_user
  end

  def ensure_mcp_user_access_token!
    return if @access_token&.owner.is_a?(User) && Current.user.is_a?(User)

    render_unauthorized('MCP requires a user API access token')
  end

  def parsed_jsonrpc_payload
    raw_body = request.raw_post.to_s
    raise JSON::ParserError, 'empty request body' if raw_body.blank?

    JSON.parse(raw_body)
  end

  def render_early_json_parse_error
    payload = JSON.generate(
      jsonrpc: Onelink::Mcp::Server::JSONRPC_VERSION,
      id: nil,
      error: { code: -32_700, message: 'Parse error' }
    )

    response.status = 400
    if sse_request?
      response.content_type = 'text/event-stream'
      self.response_body = "event: message\ndata: #{payload}\n\n"
    else
      response.content_type = 'application/json'
      self.response_body = payload
    end
  end

  def mcp_server
    @mcp_server ||= Onelink::Mcp::Server.new(auth_context: mcp_auth_context)
  end

  def mcp_auth_context
    @mcp_auth_context ||= Onelink::Mcp::AuthContext.from_controller(self)
  end

  def render_endpoint_metadata
    render json: {
      name: Onelink::Mcp::Server::SERVER_NAME,
      protocol_version: Onelink::Mcp::Server::PROTOCOL_VERSION,
      endpoint: request.path.delete_suffix('/metadata'),
      account_id: Current.account.id,
      user_id: Current.user.id,
      assistant_id: mcp_auth_context.assistant.persisted? ? mcp_auth_context.assistant.id : nil,
      methods: %w[initialize ping tools/list tools/call resources/list resources/read]
    }
  end

  def render_mcp_payload(payload, status: nil)
    status ||= if payload.is_a?(Hash) && payload[:error].is_a?(Hash)
                 http_status_for_jsonrpc_error(payload.dig(:error, :code))
               else
                 :ok
               end

    if sse_request?
      render plain: "event: message\ndata: #{JSON.generate(payload)}\n\n",
             content_type: 'text/event-stream',
             status: status
    else
      render json: payload, status: status
    end
  end

  def method_not_allowed
    response.headers['Allow'] = 'POST'
    head :method_not_allowed
  end

  def request_protocol_version
    header_value = request.get_header('HTTP_MCP_PROTOCOL_VERSION')
    return Onelink::Mcp::Server::DEFAULT_PROTOCOL_VERSION if header_value.nil?
    return header_value if Onelink::Mcp::Server::SUPPORTED_PROTOCOL_VERSIONS.include?(header_value)

    raise Onelink::Mcp::Server::JsonRpcError.new(-32_602, 'Unsupported MCP-Protocol-Version')
  end

  def json_content_type?
    request.media_type.to_s.casecmp('application/json').zero?
  end

  def valid_mcp_accept_header?
    request.headers['Accept'].blank? ||
      %w[application/json text/event-stream].any? { |type| accept_quality(type).positive? }
  end

  def ensure_mcp_origin!
    origin = request.get_header('HTTP_ORIGIN')
    return if origin.nil?

    normalized_origin = normalize_origin(origin)
    return if normalized_origin.present? && allowed_mcp_origins.include?(normalized_origin)

    Rails.logger.info('MCP request rejected: invalid Origin')
    render_jsonrpc_error(-32_600, 'Origin is not allowed', status: :forbidden)
  end

  def allowed_mcp_origins
    configured = ENV.fetch('MCP_ALLOWED_ORIGINS', '').split(',').map(&:strip).reject(&:blank?)
    configured << ENV.fetch('FRONTEND_URL', '')
    if Rails.env.development? || Rails.env.test?
      configured.concat(%w[http://localhost:3000 http://127.0.0.1:3000])
    end
    configured.filter_map { |value| normalize_origin(value, allow_path: true) }.uniq
  end

  def normalize_origin(value, allow_path: false)
    uri = URI.parse(value.to_s)
    return unless %w[http https].include?(uri.scheme.to_s.downcase)
    return if uri.host.blank? || uri.userinfo.present? || uri.query.present? || uri.fragment.present?
    return unless allow_path || uri.path.blank? || uri.path == '/'

    "#{uri.scheme.downcase}://#{uri.host.downcase}:#{uri.port}"
  rescue URI::Error, ArgumentError, RangeError
    nil
  end

  def http_status_for_jsonrpc_error(code)
    case code.to_i
    when -32_700, -32_600, -32_602
      :bad_request
    when -32_601, -32_002
      :not_found
    when -32_603
      :internal_server_error
    else
      :bad_request
    end
  end

  def sse_request?
    stream_quality = accept_quality('text/event-stream')
    json_quality = accept_quality('application/json')
    stream_quality.positive? && (json_quality.zero? || stream_quality > json_quality)
  end

  def accept_quality(media_type)
    raw_accept = request.headers['Accept'].to_s
    return 1.0 if raw_accept.blank?

    matching_ranges = raw_accept.split(',').filter_map do |entry|
      range, *parameters = entry.split(';')
      range = range.to_s.strip.downcase
      type, subtype = range.split('/', 2)
      next if type.blank? || subtype.blank?

      quality = quality_from_accept_parameters(parameters)
      expected_type, expected_subtype = media_type.split('/', 2)
      specificity = if type == expected_type && subtype == expected_subtype
                      2
                    elsif type == expected_type && subtype == '*'
                      1
                    elsif type == '*' && subtype == '*'
                      0
                    end
      next unless specificity
      quality = 0.0 unless quality.finite? && quality.between?(0.0, 1.0)
      [specificity, quality]
    end

    matching_ranges.max_by { |specificity, quality| [specificity, quality] }&.last || 0.0
  end

  def quality_from_accept_parameters(parameters)
    quality_value = parameters.filter_map do |parameter|
      key, value = parameter.split('=', 2).map { |part| part.to_s.strip }
      value if key.casecmp('q').zero?
    end.last
    return 1.0 if quality_value.nil?

    quality = Float(quality_value)
    quality.finite? && quality.between?(0.0, 1.0) ? quality : 0.0
  rescue ArgumentError, TypeError
    0.0
  end

  def render_jsonrpc_error(code, message, data: nil, status: :bad_request)
    payload = {
      jsonrpc: Onelink::Mcp::Server::JSONRPC_VERSION,
      id: nil,
      error: {
        code: code,
        message: message
      }
    }
    payload[:error][:data] = data if data.present?

    render_mcp_payload(payload, status: status)
  end
end
