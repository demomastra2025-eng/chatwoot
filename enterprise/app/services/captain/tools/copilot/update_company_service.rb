class Captain::Tools::Copilot::UpdateCompanyService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_company'
  end

  description 'Update the company linked to the current conversation contact'
  param :name, type: :string, desc: 'Updated company name', required: false
  param :domain, type: :string, desc: 'Updated company domain', required: false
  param :description, type: :string, desc: 'Updated company description', required: false

  def execute(name: nil, domain: nil, description: nil)
    company = contact_operations.update_current_company(
      name: name,
      domain: domain,
      description: description
    )
    formatted_payload(::Crm::ToolPayloadBuilder.company_payload(action: 'update_company', company: company))
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    current_company.present? && user_has_permission('contact_manage')
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
