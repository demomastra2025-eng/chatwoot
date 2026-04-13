class Api::V1::Accounts::TelegramPersonalChannelsController < Api::V1::Accounts::BaseController
  rescue_from TelegramPersonal::GatewayClient::GatewayError, with: :render_gateway_error

  before_action :fetch_inbox
  before_action :authorize_runtime_action
  before_action :validate_telegram_personal_channel
  before_action :render_pending_deletion_response,
                only: [:request_code, :request_qr, :verify_code, :verify_password, :reconnect, :history_sync, :contacts_sync, :disconnect]
  before_action :render_pending_deletion_diagnostics,
                only: [:diagnostics]

  def request_code
    sync_channel!
    result = gateway_client.request_login_code!
    apply_runtime_state!(result)
    render 'api/v1/accounts/inboxes/show'
  end

  def request_qr
    sync_channel!
    result = gateway_client.request_qr_login!
    apply_runtime_state!(result)
    render 'api/v1/accounts/inboxes/show'
  end

  def verify_code
    result = gateway_client.verify_login_code!(code: params.require(:code))
    apply_runtime_state!(result)
    render 'api/v1/accounts/inboxes/show'
  end

  def verify_password
    result = gateway_client.verify_password!(password: params.require(:password))
    apply_runtime_state!(result)
    render 'api/v1/accounts/inboxes/show'
  end

  def reconnect
    sync_channel!
    result = gateway_client.reconnect!
    apply_runtime_state!(result)
    render 'api/v1/accounts/inboxes/show'
  end

  def history_sync
    sync_channel!
    result = gateway_client.history_sync!(**history_sync_options)
    apply_runtime_state!(result)
    render 'api/v1/accounts/inboxes/show'
  end

  def contacts_sync
    sync_channel!
    result = gateway_client.contacts_sync!(**contacts_sync_options)
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
    render json: gateway_client.diagnostics
  end

  private

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:id] || params[:inbox_id])
  end

  def gateway_client
    @gateway_client ||= TelegramPersonal::GatewayClient.new(channel: @inbox.channel)
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
      last_synced_at: Time.current,
      string_session: channel_attrs[:string_session].presence || @inbox.channel.string_session
    )
  end

  def authorize_runtime_action
    authorize @inbox, :"telegram_personal_#{action_name}?"
  end

  def validate_telegram_personal_channel
    return if @inbox.telegram_personal?

    render json: { error: 'This action is only available for Telegram Personal channels' }, status: :bad_request
  end

  def render_pending_deletion_response
    return unless @inbox.deleting?

    render 'api/v1/accounts/inboxes/show', status: :accepted
  end

  def render_pending_deletion_diagnostics
    return unless @inbox.deleting?

    render json: { deleting: true }, status: :accepted
  end

  def history_sync_options
    {
      force: boolean_param(:force, default: true),
      reset_cursor: boolean_param(:reset_cursor, default: false),
      include_contacts: boolean_param(:include_contacts, default: false)
    }
  end

  def contacts_sync_options
    {
      force: boolean_param(:force, default: true)
    }
  end

  def boolean_param(key, default: false)
    return default if params[key].nil?

    ActiveModel::Type::Boolean.new.cast(params[key])
  end

  def log_telegram_personal_runtime_error(action, error)
    Rails.logger.error(
      "[TELEGRAM PERSONAL] #{action} failed for inbox=#{@inbox&.id} channel=#{@inbox&.channel&.id}: #{error.class}: #{error.message}"
    )
  end

  def render_gateway_error(error)
    log_telegram_personal_runtime_error(action_name, error)
    render json: { error: error.message }, status: :unprocessable_content
  end
end
