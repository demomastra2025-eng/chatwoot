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
    formatted_payload(::Crm::ToolPayloadBuilder.company_payload(action: 'create_company', company: company))
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
end
