class Api::V2::AccountsController < Api::BaseController
  include AuthHelper

  skip_before_action :authenticate_user!, :set_current_user, :handle_with_exception,
                     only: [:create], raise: false
  before_action :check_signup_enabled, only: [:create]
  before_action :ensure_account_name, only: [:create]
  before_action :validate_captcha, only: [:create]
  before_action :fetch_account, except: [:create]
  before_action :check_authorization, except: [:create]

  rescue_from CustomExceptions::Account::InvalidEmail,
              CustomExceptions::Account::InvalidParams,
              CustomExceptions::Account::UserExists,
              CustomExceptions::Account::UserErrors,
              with: :render_error_response

  def create
    @user, @account = signup_account

    fetch_account_and_user_info
    update_account_info if @account.present?

    if @user
      send_auth_headers(@user)
      render 'api/v1/accounts/create', format: :json, locals: { resource: @user }
    else
      render_error_response(CustomExceptions::Account::SignupFailed.new({}))
    end
  end

  private

  def signup_account
    AccountBuilder.new(
      account_name: account_params[:account_name],
      contact_phone: account_params[:contact_phone],
      company_size: account_params[:company_size],
      industry: account_params[:industry],
      industry_other: account_params[:industry_other],
      email: account_params[:email],
      user_password: account_params[:password],
      locale: account_params[:locale],
      user: current_user
    ).perform
  end

  def ensure_account_name
    raise CustomExceptions::Account::InvalidParams.new({}) if account_params[:account_name].blank?
  end

  def account_attributes
    {
      custom_attributes: @account.custom_attributes.merge({ 'onboarding_step' => 'profile_update' })
    }
  end

  def update_account_info
    @account.update!(
      account_attributes
    )
  end

  def fetch_account_and_user_info; end

  def fetch_account
    @account = current_user.accounts.find(params[:id])
    @current_account_user = @account.account_users.find_by(user_id: current_user.id)
  end

  def account_params
    params.permit(:account_name, :contact_phone, :company_size, :industry, :industry_other,
                  :email, :name, :password, :locale, :user_full_name)
  end

  def check_signup_enabled
    raise ActionController::RoutingError, 'Not Found' unless GlobalConfigService.account_signup_enabled?
  end

  def validate_captcha
    raise ActionController::InvalidAuthenticityToken, 'Invalid Captcha' unless ChatwootCaptcha.new(params[:h_captcha_client_response]).valid?
  end
end

Api::V2::AccountsController.prepend_mod_with('Api::V2::AccountsController')
