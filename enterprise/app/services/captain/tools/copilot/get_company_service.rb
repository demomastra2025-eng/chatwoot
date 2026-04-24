class Captain::Tools::Copilot::GetCompanyService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_company'
  end

  description 'Get details of a company'
  param :company_id, type: :number, desc: 'The company ID', required: true

  def execute(company_id:)
    company = account.companies.find_by(id: company_id)
    return 'Company not found' if company.blank?

    formatted_payload(company: company_payload(company))
  end

  def active?
    @user.present?
  end

  private

  def company_payload(company)
    {
      id: company.id,
      name: company.name,
      domain: company.domain,
      description: company.description,
      created_at: company.created_at&.iso8601,
      updated_at: company.updated_at&.iso8601
    }
  end
end
