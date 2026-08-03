class Captain::Tools::Copilot::GetCompanyService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_company'
  end

  description 'Get details of a company'
  param :company_id, type: :number, desc: 'The company ID', required: true

  def execute(company_id:)
    company = account.companies.find_by(id: company_id)
    return tool_failure('Company not found') if company.blank?

    formatted_payload(company: ::Crm::PayloadBuilder.company(company))
  end

  def active?
    user_has_permission('contact_manage')
  end
end
