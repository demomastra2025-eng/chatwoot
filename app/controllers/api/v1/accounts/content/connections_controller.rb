class Api::V1::Accounts::Content::ConnectionsController < Api::V1::Accounts::Content::BaseController
  def show
    render_payload(postiz_hook_payload(Current.account.hooks.find_by(app_id: 'postiz')))
  end

  def update
    hook = Current.account.hooks.find_or_initialize_by(app_id: 'postiz')
    if hook.new_record? && connection_params[:access_token].blank?
      return render_error(
        code: 'POSTIZ_CONNECTION_MISSING',
        message: 'Postiz API key is required before saving the connection',
        status: :unprocessable_content
      )
    end

    hook.status = connection_status if connection_status.present?
    hook.settings = sanitized_settings if params.key?(:settings)
    hook.access_token = connection_params[:access_token].to_s.strip if connection_params[:access_token].present?
    hook.save!

    render_payload(postiz_hook_payload(hook))
  end

  def destroy
    Current.account.hooks.find_by(app_id: 'postiz')&.destroy!
    render_payload({ connected: false, enabled: false, settings: {} })
  end

  def test
    hook = Current.account.hooks.find_by(app_id: 'postiz')
    if hook&.access_token.blank?
      return render_error(
        code: 'POSTIZ_CONNECTION_MISSING',
        message: 'Postiz API key is not configured',
        status: :unprocessable_content
      )
    end

    result = postiz_client.test_connection
    status = result[:connected] ? :ok : :bad_gateway
    render_payload(result, status: status)
  end

  private

  def connection_params
    params.permit(:access_token, :status, settings: [:organization_id, :default_timezone])
  end

  def connection_status
    raw_status = connection_params[:status]
    return if raw_status.blank?
    return raw_status if %w[enabled disabled].include?(raw_status)

    ActiveModel::Type::Boolean.new.cast(raw_status) ? 'enabled' : 'disabled'
  end

  def sanitized_settings
    allowed = connection_params.fetch(:settings, {}).to_h
    allowed.transform_values { |value| value.is_a?(String) ? value.strip : value }.compact_blank
  end
end
