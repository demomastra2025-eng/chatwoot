module AccessTokenAuthHelper
  def ensure_access_token
    token = request.headers[:api_access_token] || request.headers[:HTTP_API_ACCESS_TOKEN]
    @access_token = AccessToken.find_by(token: token) if token.present?
  end

  def authenticate_access_token!
    ensure_access_token
    render_unauthorized('Invalid Access Token') && return if @access_token.blank?

    # NOTE: This ensures that current_user is set and available for the rest of the controller actions
    @resource = @access_token.owner
    Current.user = @resource if allowed_current_user_type?(@resource)
  end

  def allowed_current_user_type?(resource)
    resource.is_a?(User)
  end

  # Only users authenticate with a personal access token on the account API; any other token owner is refused.
  def validate_bot_access_token!
    return if Current.user.is_a?(User)

    render_unauthorized('Access to this endpoint is not authorized for this token')
  end
end
