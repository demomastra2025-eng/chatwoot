class Captain::Tools::Copilot::SearchCompaniesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_companies'
  end

  description 'Search companies by name or domain'
  param :name, type: :string, desc: 'Company name query', required: false
  param :domain, type: :string, desc: 'Company domain query', required: false
  param :limit, type: :number, desc: 'Maximum number of companies to return', required: false

  def execute(name: nil, domain: nil, limit: nil)
    companies = account.companies.order(:name, :id)
    companies = companies.where('LOWER(name) ILIKE ?', "%#{name.to_s.downcase}%") if name.present?
    companies = companies.where('LOWER(domain) ILIKE ?', "%#{domain.to_s.downcase}%") if domain.present?

    total_count = companies.count
    records = companies.limit(parse_limit(limit)).map { |company| ::Crm::PayloadBuilder.company(company) }

    formatted_payload(
      filters: {
        name: name,
        domain: domain
      }.compact,
      total_count: total_count,
      companies: records
    )
  end

  def active?
    @user.present?
  end
end
