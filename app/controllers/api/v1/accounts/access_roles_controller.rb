class Api::V1::Accounts::AccessRolesController < Api::V1::Accounts::BaseController
  before_action :fetch_access_role, only: [:update, :destroy]
  before_action :check_authorization

  rescue_from AccessControl::AccessRoleMutator::Error, with: :render_mutation_error

  def index
    @access_roles = Current.account.access_roles.includes(:grants).order(:id)
    @assignment_counts = Current.account.account_users.where.not(access_role_id: nil).group(:access_role_id).count
  end

  def create
    @access_role = AccessControl::AccessRoleMutator.create(
      account: Current.account,
      attributes: permitted_params.to_h
    )
    @assigned_users_count = 0
    render :show, status: :created
  end

  def update
    @access_role = AccessControl::AccessRoleMutator.update(
      account: Current.account,
      access_role: @access_role,
      attributes: permitted_params.to_h
    )
    @assigned_users_count = Current.account.account_users.where(access_role_id: @access_role.id).count
    render :show
  end

  def destroy
    AccessControl::AccessRoleMutator.destroy(
      account: Current.account,
      access_role: @access_role,
      lock_version: permitted_lock_version
    )
    head :ok
  end

  private

  def fetch_access_role
    @access_role = Current.account.access_roles.find(params[:id])
  end

  def permitted_params
    params.require(:access_role).permit(:name, :description, :lock_version, grants: [:resource, :capability, :access_scope])
  end

  def permitted_lock_version
    params.require(:access_role).require(:lock_version)
  end

  def render_mutation_error(error)
    render json: { error: error.message, code: error.code }, status: error.status
  end
end
