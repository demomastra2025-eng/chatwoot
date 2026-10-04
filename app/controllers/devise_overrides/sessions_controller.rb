class DeviseOverrides::SessionsController < DeviseTokenAuth::SessionsController
  # Prevent session parameter from being passed
  # Unpermitted parameter: session
  wrap_parameters format: []
  before_action :process_sso_auth_token, only: [:create]

  def new
    redirect_to login_page_url(error: 'access-denied'), allow_other_host: true
  end

  def create
    return handle_mfa_verification if mfa_verification_request?
    return handle_sso_authentication if sso_authentication_request?

    user = find_user_for_authentication
    return handle_mfa_required(user) if user&.mfa_enabled?

    # Only proceed with standard authentication if no MFA is required
    super
  end

  def render_create_success
    finalize_authenticated_session!
    render partial: 'devise/auth', formats: [:json],
           locals: { resource: @resource, impersonation_context: @impersonation_context }
  end

  def destroy
    current_client_id = request.headers[DeviseTokenAuth.headers_names[:client]]
    SuperAdmin::ImpersonationService.revoke!(current_client_id)

    super do |user|
      user.clear_active_auth_client!(current_client_id)
    end
  end

  private

  def finalize_authenticated_session!
    return if @impersonation_grant

    previous_client_id = @resource.activate_auth_client!(
      @token.client,
      device_type: current_auth_device_type
    )
    @resource.broadcast_session_replaced!(previous_client_id)
  end

  def current_auth_device_type
    Auth::SessionDeviceClassifier.call(request.user_agent)
  end

  def find_user_for_authentication
    return nil unless params[:email].present? && params[:password].present?

    normalized_email = params[:email].strip.downcase
    user = User.from_email(normalized_email)
    return nil unless user&.valid_password?(params[:password])
    return nil unless user.active_for_authentication?

    user
  end

  def mfa_verification_request?
    params[:mfa_token].present?
  end

  def sso_authentication_request?
    @impersonation_grant_attempt || (params[:sso_auth_token].present? && @resource.present?)
  end

  def handle_sso_authentication
    return render_impersonation_auth_error unless authenticate_resource_with_sso_token

    yield @resource if block_given?
    render_create_success
  end

  def login_page_url(error: nil)
    frontend_url = ENV.fetch('FRONTEND_URL', nil)

    "#{frontend_url}/app/login?error=#{error}"
  end

  def authenticate_resource_with_sso_token
    return false if @impersonation_grant_attempt && (@resource.blank? || @impersonation_grant.blank?)

    if @impersonation_grant_attempt
      return false unless SuperAdmin::ImpersonationService.consume_grant!(
        user: @resource, token: params[:sso_auth_token], grant: @impersonation_grant
      )

      @token = @resource.create_token(
        client: @impersonation_grant['client_id'],
        lifespan: SuperAdmin::ImpersonationService::SESSION_TTL.to_i
      )
      @impersonation_context = SuperAdmin::ImpersonationService.context_for_request(
        @impersonation_grant['client_id'], target_user_id: @resource.id
      )
      return false unless @impersonation_context
    else
      @token = @resource.create_token
    end
    @resource.save!

    sign_in(:user, @resource, store: false, bypass: false)
    @resource.invalidate_sso_auth_token(params[:sso_auth_token])
    true
  end

  def process_sso_auth_token
    token = params[:sso_auth_token].to_s
    return if token.blank?

    @impersonation_grant_attempt = SuperAdmin::ImpersonationService.impersonation_grant_token?(token)
    return if params[:email].blank?

    user = User.from_email(params[:email])
    return unless user&.valid_sso_auth_token?(token)

    if @impersonation_grant_attempt
      @impersonation_grant = SuperAdmin::ImpersonationService.grant_for(user: user, token: token)
      return unless @impersonation_grant
    end
    @resource = user
  end

  def render_impersonation_auth_error
    render json: { error: I18n.t('auth.session_replaced'), code: 'session_replaced' }, status: :unauthorized
  end

  def handle_mfa_required(user)
    render json: {
      mfa_required: true,
      mfa_token: Mfa::TokenService.new(user: user).generate_token
    }, status: :partial_content
  end

  def handle_mfa_verification
    user = Mfa::TokenService.new(token: params[:mfa_token]).verify_token
    return render_mfa_error('errors.mfa.invalid_token', :unauthorized) unless user

    authenticated = Mfa::AuthenticationService.new(
      user: user,
      otp_code: params[:otp_code],
      backup_code: params[:backup_code]
    ).authenticate

    return render_mfa_error('errors.mfa.invalid_code') unless authenticated

    sign_in_mfa_user(user)
  end

  def sign_in_mfa_user(user)
    @resource = user
    @token = @resource.create_token
    @resource.save!

    sign_in(:user, @resource, store: false, bypass: false)
    render_create_success
  end

  def render_mfa_error(message_key, status = :bad_request)
    render json: { error: I18n.t(message_key) }, status: status
  end
end

DeviseOverrides::SessionsController.prepend_mod_with('DeviseOverrides::SessionsController')
