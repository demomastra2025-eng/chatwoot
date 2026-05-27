class Api::V1::Accounts::Companies::ContactsController < Api::V1::Accounts::Companies::BaseController
  RESULTS_PER_PAGE = 15
  CONTACT_SEARCH_QUERY = [
    'contacts.name ILIKE :search',
    'contacts.email ILIKE :search',
    'contacts.phone_number ILIKE :search',
    'contacts.identifier ILIKE :search'
  ].join(' OR ')

  before_action :authorize_company_read!, only: [:index, :search]
  before_action :authorize_company_update!, only: [:create, :destroy]
  before_action :set_current_page, only: [:index, :search]
  before_action :fetch_contact, only: [:destroy]

  def index
    @contacts = fetch_contacts(effective_company_contacts.order(:name, :id))
    @contacts_count = @contacts.total_count
  end

  def search
    if params[:q].blank?
      return render json: { error: I18n.t('errors.contacts.search.query_missing') },
                    status: :unprocessable_content
    end

    @contacts = fetch_contacts(contact_search_scope)
    @contacts_count = @contacts.total_count
  end

  def create
    @contact = Current.account.contacts.find(params[:contact_id])
    membership_service.assign(contact: @contact)
  end

  def destroy
    membership_service.remove(contact: @contact)
    head :ok
  end

  private

  def set_current_page
    @current_page = params[:page] || 1
  end

  def fetch_contact
    @contact = @company.contacts.find(params[:id])
  end

  def fetch_contacts(contacts)
    contacts
      .includes({ avatar_attachment: [:blob] }, :company)
      .page(@current_page)
      .per(RESULTS_PER_PAGE)
  end

  def effective_company_contacts
    contact_ids = effective_company_contact_ids
    return Current.account.contacts.none if contact_ids.empty?

    Current.account.contacts.where(id: contact_ids)
  end

  def effective_company_contact_ids
    direct_contact_ids = @company.contacts.pluck(:id)
    deal_contact_ids = Current.account.crm_deal_contacts
                              .joins(:deal)
                              .where(crm_deals: { company_id: @company.id })
                              .pluck(:contact_id)

    (direct_contact_ids + deal_contact_ids).uniq
  end

  def contact_search_scope
    Current.account.contacts
           .where.not(id: @company.contacts.select(:id))
           .where(CONTACT_SEARCH_QUERY, search: "%#{params[:q].strip}%")
           .order(:name, :id)
  end

  def membership_service
    @membership_service ||= Companies::ContactMembershipService.new(company: @company)
  end
end
