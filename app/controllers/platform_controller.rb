# The base of the Platform API: a partner (a PlatformApp, identified by the token in the `api_access_token` header)
# creates accounts and users for its own customers. A partner reads and changes only what it created itself (the
# `platform_app_permissibles` of its access), and every call that changes something leaves an entry in the audit log
# with the partner as the actor.
class PlatformController < ActionController::API
  include RequestExceptionHandler

  before_action :ensure_access_token
  before_action :set_platform_app
  before_action :set_resource, only: [:update, :show, :destroy]
  before_action :validate_platform_app_permissible, only: [:update, :show, :destroy]

  def show; end

  def update; end

  def destroy; end

  private

  def ensure_access_token
    token = request.headers[:api_access_token] || request.headers[:HTTP_API_ACCESS_TOKEN]
    @access_token = AccessToken.find_by(token: token) if token.present?
  end

  def set_platform_app
    @platform_app = @access_token.owner if @access_token && @access_token.owner.is_a?(PlatformApp)
    render json: { error: 'Invalid access_token' }, status: :unauthorized if @platform_app.blank?
  end

  def set_resource
    # set @resource in your controller
    raise 'Overwrite this method your controller'
  end

  def validate_platform_app_permissible
    return if @platform_app.owns?(@resource)

    render_non_permissible
  end

  def render_non_permissible
    render json: { error: 'Non permissible resource' }, status: :unauthorized
  end

  # An entry of the audit log for something done to one account (the changes carry names and values of settings, never
  # a secret)
  def audit_account(account, action, changes = {})
    SuperAdmin::AccountAudit.record(account: account, actor: @platform_app, action: action, changes: changes, request: request)
  end

  # An entry of the audit log for something done to another record (a user)
  def audit_record(record, action, changes = {})
    SuperAdmin::PlatformAudit.record(auditable: record, action: action, actor: @platform_app, changes: changes, request: request)
  end
end
