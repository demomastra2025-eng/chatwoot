class DeviseOverrides::PasswordsController < Devise::PasswordsController
  include AuthHelper

  skip_before_action :require_no_authentication, raise: false
  skip_before_action :authenticate_user!, raise: false
  before_action :reject_impersonation_credential_change!, only: [:update]

  def create
    @user = User.from_email(params[:email])
    @user&.send_reset_password_instructions
    build_response(I18n.t('messages.reset_password'), 200)
  end

  def update
    # params: reset_password_token, password, password_confirmation
    original_token = params[:reset_password_token]
    reset_password_token = Devise.token_generator.digest(self, :reset_password_token, original_token)
    @recoverable = User.find_by(reset_password_token: reset_password_token)
    if @recoverable && reset_password_and_confirmation(@recoverable)
      send_auth_headers(@recoverable)
      render partial: 'devise/auth', formats: [:json], locals: { resource: @recoverable }
    else
      render json: { message: 'Invalid token', redirect_url: '/' }, status: :unprocessable_content
    end
  end

  private

  def reject_impersonation_credential_change!
    client_id = request.headers[DeviseTokenAuth.headers_names[:client]].to_s
    return unless client_id.start_with?(SuperAdmin::ImpersonationService::CLIENT_PREFIX)

    render json: { error: I18n.t('auth.session_replaced'), code: 'session_replaced' }, status: :unauthorized
  end

  def reset_password_and_confirmation(recoverable)
    recoverable.confirm unless recoverable.confirmed? # confirm if user resets password without confirming anytime before
    recoverable.reset_password(params[:password], params[:password_confirmation])
    recoverable.reset_password_token = nil
    recoverable.confirmation_token = nil
    recoverable.reset_password_sent_at = nil
    recoverable.save!
  end

  def build_response(message, status)
    render json: {
      message: message
    }, status: status
  end
end

DeviseOverrides::PasswordsController.prepend_mod_with('DeviseOverrides::PasswordsController')
