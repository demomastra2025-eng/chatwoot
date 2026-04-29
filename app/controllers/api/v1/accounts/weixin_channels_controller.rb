class Api::V1::Accounts::WeixinChannelsController < Api::V1::Accounts::BaseController
  rescue_from Weixin::GatewayClient::GatewayError, with: :render_gateway_error

  before_action :fetch_inbox
  before_action :authorize_runtime_action
  before_action :validate_weixin_channel
  before_action :render_pending_deletion_response, only: [:request_qr, :reconnect, :disconnect]
  before_action :render_pending_deletion_diagnostics, only: [:diagnostics]

  def request_qr
    sync_channel!
    result = gateway_client.request_qr_login!
    apply_runtime_state!(result)
    render 'api/v1/accounts/inboxes/show'
  end

  def reconnect
    sync_channel!
    result = gateway_client.reconnect!
    apply_runtime_state!(result)
    render 'api/v1/accounts/inboxes/show'
  end

  def disconnect
    result = gateway_client.disconnect!
    apply_runtime_state!(result)
    render 'api/v1/accounts/inboxes/show'
  end

  def diagnostics
    sync_channel!
    result = gateway_client.diagnostics
    apply_runtime_state!(result)
    @inbox.reload
    render 'api/v1/accounts/inboxes/show'
  end

  private

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:id] || params[:inbox_id])
  end

  def gateway_client
    @gateway_client ||= Weixin::GatewayClient.new(channel: @inbox.channel)
  end

  def sync_channel!
    gateway_client.sync_channel!
  end

  def apply_runtime_state!(result)
    channel_attrs = result.with_indifferent_access[:channel]
    return if channel_attrs.blank?

    @inbox.channel.apply_runtime_update!(
      connection_state: channel_attrs[:connection_state],
      lifecycle_state: channel_attrs[:lifecycle_state],
      last_error: channel_attrs[:last_error],
      runtime_state: channel_attrs[:runtime_state],
      context_token: channel_attrs[:context_token].presence || @inbox.channel.context_token,
      ilink_token: channel_attrs[:ilink_token].presence || @inbox.channel.ilink_token,
      provider_account_id: channel_attrs[:provider_account_id].presence || @inbox.channel.provider_account_id,
      display_name: channel_attrs[:display_name].presence || @inbox.channel.display_name,
      last_synced_at: Time.current
    )
  end

  def authorize_runtime_action
    authorize @inbox, :"weixin_#{action_name}?"
  end

  def validate_weixin_channel
    return if @inbox.weixin?

    render json: { error: 'This action is only available for Weixin channels' }, status: :bad_request
  end

  def render_pending_deletion_response
    return unless @inbox.deleting?

    render 'api/v1/accounts/inboxes/show', status: :accepted
  end

  def render_pending_deletion_diagnostics
    return unless @inbox.deleting?

    render json: { deleting: true }, status: :accepted
  end

  def log_weixin_runtime_error(action, error)
    Rails.logger.error("[WEIXIN] #{action} failed for inbox=#{@inbox&.id} channel=#{@inbox&.channel&.id}: #{error.class}: #{error.message}")
  end

  def render_gateway_error(error)
    log_weixin_runtime_error(action_name, error)
    render json: { error: error.message }, status: :unprocessable_content
  end
end
