class Api::BaseController < ApplicationController
  include AccessTokenAuthHelper
  include ActiveAuthSessionEnforcer
  respond_to :json
  before_action :authenticate_access_token!, if: :authenticate_by_access_token?
  before_action :validate_bot_access_token!, if: :authenticate_by_access_token?
  before_action :authenticate_user!, unless: :authenticate_by_access_token?
  before_action :ensure_active_auth_session!, unless: :authenticate_by_access_token?
  before_action :enforce_super_admin_impersonation_scope!, unless: :authenticate_by_access_token?

  private

  def authenticate_by_access_token?
    request.headers[:api_access_token].present? || request.headers[:HTTP_API_ACCESS_TOKEN].present?
  end

  def enforce_super_admin_impersonation_scope!
    return unless @super_admin_impersonation
    return if account_scoped_impersonation_request? || impersonation_profile_request?

    render_unauthorized('Impersonation is restricted to one account')
  end

  def account_scoped_impersonation_request?
    # Collection signup creates global credentials and is never an account-scoped admin action.
    return false if controller_path == 'api/v1/accounts' && action_name == 'create'
    return false unless controller_path == 'api/v1/accounts' || controller_path.start_with?('api/v1/accounts/')

    account_id = params[:account_id].presence || (params[:id] if controller_path == 'api/v1/accounts')
    account_id.present? && account_id.to_s == @super_admin_impersonation['account_id'].to_s
  end

  def impersonation_profile_request?
    request.get? && controller_path == 'api/v1/profiles' && action_name == 'show'
  end

  def check_authorization(model = nil)
    model ||= controller_name.classify.constantize

    authorize(model)
  end

  def check_admin_authorization?
    raise Pundit::NotAuthorizedError unless Current.account_user.administrator?
  end
end
