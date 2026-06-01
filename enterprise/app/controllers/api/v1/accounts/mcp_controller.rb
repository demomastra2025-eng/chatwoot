# frozen_string_literal: true

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

  def handle
    return render_endpoint_metadata if request.get?

    payload = parsed_jsonrpc_payload
    response_payload = mcp_server.call(payload)
    return head :accepted if response_payload.nil?

    render_mcp_payload(response_payload)
  rescue JSON::ParserError
    render_jsonrpc_error(-32_700, 'Parse error', status: :bad_request)
  rescue ActiveRecord::RecordNotFound => e
    render_jsonrpc_error(-32_602, e.message, status: :not_found)
  rescue Onelink::Mcp::Server::JsonRpcError => e
    render_jsonrpc_error(e.code, e.message, data: e.data, status: :bad_request)
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
      endpoint: request.path,
      account_id: Current.account.id,
      user_id: Current.user.id,
      assistant_id: mcp_auth_context.assistant.persisted? ? mcp_auth_context.assistant.id : nil,
      methods: %w[initialize ping tools/list tools/call resources/list resources/read]
    }
  end

  def render_mcp_payload(payload)
    if sse_request?
      render plain: "event: message\ndata: #{JSON.generate(payload)}\n\n", content_type: 'text/event-stream'
    else
      render json: payload
    end
  end

  def sse_request?
    request.headers['Accept'].to_s.include?('text/event-stream')
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

    render json: payload, status: status
  end
end
