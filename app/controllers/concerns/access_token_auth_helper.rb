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
    Current.user = @resource if @resource.is_a?(User)
  end

  def validate_bot_access_token!
    return if Current.user.is_a?(User)
    render_unauthorized('Access to this endpoint is not authorized for bots')
  end
end
