class Api::V1::Accounts::BillingOverviewController < Api::V1::Accounts::BaseController
  before_action :check_authorization

  def show
    render json: Billing::OverviewBuilder.new(account: Current.account, user: Current.user).call
  end

  private

  def check_authorization
    raise Pundit::NotAuthorizedError unless Current.account_user&.administrator?
  end
end
