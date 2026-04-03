class Captain::Tools::Copilot::SearchCompaniesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_companies'
  end

  description 'Search companies by name or domain'
  param :name, type: :string, desc: 'Company name query', required: false
  param :domain, type: :string, desc: 'Company domain query', required: false

  def execute(name: nil, domain: nil)
    companies = account.companies.order(:name)
    companies = companies.where('LOWER(name) ILIKE ?', "%#{name.to_s.downcase}%") if name.present?
    companies = companies.where('LOWER(domain) ILIKE ?', "%#{domain.to_s.downcase}%") if domain.present?

    formatted_collection(companies.limit(MAX_RESULTS))
  end

  def active?
    @user.present?
  end
end
