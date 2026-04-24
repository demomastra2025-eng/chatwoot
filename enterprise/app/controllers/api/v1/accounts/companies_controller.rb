class Api::V1::Accounts::CompaniesController < Api::V1::Accounts::EnterpriseAccountsController
  include Sift
  sort_on :name, type: :string
  sort_on :domain, type: :string
  sort_on :created_at, type: :datetime
  sort_on :contacts_count, internal_name: :order_on_contacts_count, type: :scope, scope_params: [:direction]

  RESULTS_PER_PAGE = 25

  before_action :check_authorization
  before_action :set_current_page, only: [:index, :search]
  before_action :fetch_company, only: [:show, :update, :destroy]

  def index
    @companies = fetch_companies(resolved_companies)
    @companies_count = @companies.total_count
  end

  def search
    if params[:q].blank?
      return render json: { error: I18n.t('errors.companies.search.query_missing') },
                    status: :unprocessable_content
    end

    companies = resolved_companies.search_by_name_or_domain(params[:q])
    @companies = fetch_companies(companies)
    @companies_count = @companies.total_count
  end

  def show; end

  def create
    @company = Current.account.companies.build(company_params)
    @company.save!
  end

  def update
    @company.update!(company_params)
  end

  def destroy
    @company.destroy!
    head :ok
  end

  private

  def resolved_companies
    @resolved_companies ||= Current.account.companies.with_effective_contacts_count.with_attached_avatar
  end

  def set_current_page
    @current_page = params[:page] || 1
  end

  def fetch_companies(companies)
    filtrate(companies)
      .page(@current_page)
      .per(RESULTS_PER_PAGE)
  end

  def check_authorization
    raise Pundit::NotAuthorizedError unless ChatwootApp.enterprise?

    authorize(Company)
  end

  def fetch_company
    company_scope = Current.account.companies.with_effective_contacts_count.with_attached_avatar
    if action_name == 'show'
      company_scope =
        company_scope.includes(contacts: { avatar_attachment: :blob })
    end
    @company = company_scope.find(params[:id])
    @company_contacts = fetch_company_contacts if action_name == 'show'
  end

  def fetch_company_contacts
    direct_contact_ids = @company.contacts.pluck(:id)
    deal_contact_ids = Current.account.crm_deal_contacts
                              .joins(:deal)
                              .where(crm_deals: { company_id: @company.id })
                              .pluck(:contact_id)

    contact_ids = (direct_contact_ids + deal_contact_ids).uniq
    return Contact.none if contact_ids.empty?

    Current.account.contacts
           .includes(avatar_attachment: :blob)
           .where(id: contact_ids)
           .order(:name)
  end

  def company_params
    params.require(:company).permit(:name, :domain, :description, :avatar)
  end
end
