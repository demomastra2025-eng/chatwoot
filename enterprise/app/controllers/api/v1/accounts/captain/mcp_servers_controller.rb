class Api::V1::Accounts::Captain::McpServersController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Captain::McpServer) }
  before_action :set_mcp_server,
                only: [:show, :update, :destroy, :surface, :read_resource, :fetch_resource_template, :fetch_prompt,
                       :task_get, :task_result, :task_cancel, :oauth_start, :oauth_disconnect]

  def index
    @mcp_servers = account_mcp_servers.order(created_at: :desc)
  end

  def show; end

  def create
    @mcp_server = account_mcp_servers.create!(mcp_server_params)
  end

  def update
    @mcp_server.update!(mcp_server_params)
  end

  def destroy
    @mcp_server.destroy
    head :no_content
  end

  def test
    mcp_server = build_preview_mcp_server
    return render_could_not_create_error(mcp_server.errors.full_messages.join(', ')) unless mcp_server.valid?

    surface = Captain::Mcp::ServerSurfaceService.new(mcp_server).snapshot

    render json: {
      tools: surface[:tools],
      resources: surface[:resources],
      resource_templates: surface[:resource_templates],
      prompts: surface[:prompts],
      tasks: surface[:tasks],
      capabilities: surface[:capabilities],
      total_count: surface[:tools].length
    }
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def surface
    render json: surface_service.snapshot
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def read_resource
    render json: surface_service.read_resource(uri: params.require(:uri))
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def fetch_resource_template
    render json: surface_service.fetch_resource_template(
      name: params.require(:name),
      arguments: operation_arguments
    )
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def fetch_prompt
    render json: surface_service.fetch_prompt(
      name: params.require(:name),
      arguments: operation_arguments
    )
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def task_get
    render json: surface_service.task_get(task_id: params.require(:task_id))
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def task_result
    render json: surface_service.task_result(task_id: params.require(:task_id))
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def task_cancel
    render json: surface_service.task_cancel(task_id: params.require(:task_id))
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def oauth_start
    return render_could_not_create_error('OAuth is only supported for HTTP MCP transports') unless @mcp_server.http_transport?
    return render_could_not_create_error('MCP server URL is required for OAuth') if @mcp_server.server_url.blank?

    provider = RubyLLM::MCP::Auth::OAuthProvider.new(
      server_url: @mcp_server.server_url,
      redirect_uri: captain_mcp_oauth_callback_url,
      scope: @mcp_server.oauth_scope,
      storage: Captain::Mcp::OauthStorage.new(@mcp_server)
    )
    authorization_url = provider.start_authorization_flow
    @mcp_server.update!(oauth_return_url: safe_return_url(params[:return_url]))

    render json: {
      authorization_url: authorization_url,
      callback_url: captain_mcp_oauth_callback_url,
      oauth_status: @mcp_server.reload.oauth_status
    }
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def oauth_disconnect
    @mcp_server.disconnect_oauth!

    render json: {
      id: @mcp_server.id,
      oauth_status: @mcp_server.reload.oauth_status
    }
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  private

  def set_mcp_server
    @mcp_server = account_mcp_servers.find(params[:id])
  end

  def account_mcp_servers
    @account_mcp_servers ||= Current.account.captain_mcp_servers
  end

  def mcp_server_params
    permitted = params.require(:mcp_server).permit(
      :name,
      :description,
      :transport_type,
      :request_timeout,
      :enabled,
      allowed_scopes: []
    )

    if params[:mcp_server].respond_to?(:key?) && params[:mcp_server].key?(:server_config)
      raw_server_config = params[:mcp_server][:server_config]
      permitted[:server_config] = if raw_server_config.respond_to?(:permit!)
                                    raw_server_config.permit!.to_h
                                  elsif raw_server_config.respond_to?(:to_h)
                                    raw_server_config.to_h
                                  else
                                    raw_server_config
                                  end
    end

    permitted
  end

  def build_preview_mcp_server
    account_mcp_servers.new(mcp_server_params.merge(slug: "preview_#{SecureRandom.hex(6)}"))
  end

  def surface_service
    @surface_service ||= Captain::Mcp::ServerSurfaceService.new(@mcp_server)
  end

  def operation_arguments
    raw_arguments = params[:arguments] || {}
    return raw_arguments.permit!.to_h if raw_arguments.respond_to?(:permit!)
    return raw_arguments.to_h if raw_arguments.respond_to?(:to_h)

    {}
  end

  def safe_return_url(raw_url)
    return if raw_url.blank?

    uri = URI.parse(raw_url)
    return raw_url if uri.relative? && raw_url.start_with?('/app/')
    return raw_url if uri.host == request.host && uri.path.start_with?('/app/')
  rescue URI::InvalidURIError
    nil
  end
end
