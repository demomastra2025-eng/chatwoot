class Api::V1::Accounts::Companies::BaseController < Api::V1::Accounts::EnterpriseAccountsController
  before_action :fetch_company

  private

  def fetch_company
    @company = Current.account.companies.with_effective_contacts_count.with_attached_avatar.find(params[:company_id])
  end

  def authorize_company_read!
    authorize(@company, :show?)
  end

  def authorize_company_update!
    authorize(@company, :update?)
  end
end
