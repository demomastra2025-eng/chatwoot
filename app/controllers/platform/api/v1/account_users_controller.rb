# Members of an account of the partner. Both the account and the user must be the partner's own: a partner cannot put a
# user it did not create (an operator of another customer, a super admin) into its account or take one out.
class Platform::Api::V1::AccountUsersController < PlatformController
  before_action :set_resource
  before_action :validate_platform_app_permissible
  before_action :validate_user_permissible, only: [:create, :destroy]

  def index
    render json: @resource.account_users
  end

  def create
    @account_user = @resource.account_users.find_or_initialize_by(user_id: account_user_params[:user_id])
    added = @account_user.new_record?
    @account_user.update!(account_user_params)
    audit_account(@resource, 'partner_set_account_user',
                  'user_id' => @account_user.user_id, 'role' => @account_user.role, 'added' => added)
    render json: @account_user
  end

  def destroy
    membership = @resource.account_users.find_by(user_id: account_user_params[:user_id])
    return head :ok if membership.nil?

    membership.destroy!
    audit_account(@resource, 'partner_remove_account_user', 'user_id' => membership.user_id, 'role' => membership.role)
    head :ok
  end

  private

  def set_resource
    @resource = Account.find(params[:account_id])
  end

  def validate_user_permissible
    user = User.find_by(id: account_user_params[:user_id])
    return if user && @platform_app.owns?(user) && !user.is_a?(SuperAdmin)

    render_non_permissible
  end

  def account_user_params
    params.permit(:user_id, :role)
  end
end
