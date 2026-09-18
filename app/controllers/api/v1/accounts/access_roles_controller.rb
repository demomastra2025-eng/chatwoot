class Api::V1::Accounts::AccessRolesController < Api::V1::Accounts::BaseController
  before_action :check_authorization

  def index
    @access_roles = Current.account.access_roles.includes(:grants).order(:id)
    @assignment_counts = Current.account.account_users.where.not(access_role_id: nil).group(:access_role_id).count
  end
end
