module AccessTokenAuthHelper
  BEARER_TOKEN_PATTERN = /\ABearer\s+(\S+)\s*\z/i
  MAX_DEVISE_BEARER_BYTES = 4096

  def ensure_access_token
    token = request_access_token
    @access_token = AccessToken.find_by(token: token) if token.present?
  end

  def access_token_request?
    request_access_token.present?
  end

  def authenticate_access_token!
    ensure_access_token
    render_unauthorized('Invalid Access Token') && return if @access_token.blank?

    # NOTE: This ensures that current_user is set and available for the rest of the controller actions,
    # and clears any pre-populated DeviseTokenAuth user when authenticating with a non-User token.
    @resource = @access_token.owner
    Current.api_access_token_authenticated = true
    Current.user = allowed_current_user_type?(@resource) ? @resource : nil
  end

  def allowed_current_user_type?(resource)
    resource.is_a?(User)
  end

  # Only users authenticate with a personal access token on the account API; any other token owner is refused.
  def validate_bot_access_token!
    return if @access_token&.owner.is_a?(User) && Current.user.is_a?(User)

    render_unauthorized('Access to this endpoint is not authorized for this token')
  end

  private

  def request_access_token
    explicit_access_token || bearer_access_token
  end

  def explicit_access_token
    request.headers[:api_access_token].presence || request.headers[:HTTP_API_ACCESS_TOKEN].presence
  end

  def bearer_access_token
    token = request.authorization.to_s[BEARER_TOKEN_PATTERN, 1]
    return if token.blank? || devise_token_auth_bearer?(token)

    token
  end

  def devise_token_auth_bearer?(token)
    return false if token.bytesize > MAX_DEVISE_BEARER_BYTES

    decoded = Base64.decode64(token.tr('-_', '+/'))
    return false unless decoded.valid_encoding?

    parsed = JSON.parse(decoded)
    parsed.is_a?(Hash) && parsed.key?('access-token') && parsed.key?('uid')
  rescue JSON::ParserError, ArgumentError
    false
  end
end
