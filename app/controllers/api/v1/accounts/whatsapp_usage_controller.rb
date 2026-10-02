class Api::V1::Accounts::WhatsappUsageController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?

  def show
    render json: { whatsapp_usage: Whatsapp::MonthlyUsageService.new(account: Current.account).perform }
  end
end
