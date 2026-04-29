module ActiveAuthSessionEnforcer
  extend ActiveSupport::Concern

  private

  def ensure_active_auth_session!
    return unless current_user.is_a?(User)

    client_id = current_auth_client_id
    return render_session_replaced_error if client_id.blank?

    if current_user.active_auth_client_ids.blank?
      current_user.activate_auth_client!(client_id, device_type: current_auth_device_type)
      return
    end

    return if current_user.active_auth_client?(client_id)

    render_session_replaced_error
  end

  def current_auth_client_id
    @token&.client.presence || request.headers[DeviseTokenAuth.headers_names[:client]].presence
  end

  def current_auth_device_type
    Auth::SessionDeviceClassifier.call(request.user_agent)
  end

  def render_session_replaced_error
    render json: {
      error: I18n.t('auth.session_replaced'),
      code: 'session_replaced'
    }, status: :unauthorized
  end
end
