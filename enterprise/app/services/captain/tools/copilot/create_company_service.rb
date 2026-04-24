class Captain::Tools::Copilot::CreateCompanyService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_company'
  end

  description 'Create a company for the current conversation contact'
  param :name, type: :string, desc: 'Company name', required: true
  param :domain, type: :string, desc: 'Company domain', required: false
  param :description, type: :string, desc: 'Company description', required: false

  def execute(name:, domain: nil, description: nil)
    company = contact_operations.create_company_for_current_contact(
      name: name,
      domain: domain,
      description: description
    )
    formatted_payload(
      action: 'create_company',
      company: company_payload(company)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    current_contact.present? && user_has_permission('contact_manage')
  end

  private

  def contact_operations
    Captain::Tools::Operations::ContactOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end

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
