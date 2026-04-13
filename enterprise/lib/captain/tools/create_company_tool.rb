class Captain::Tools::CreateCompanyTool < Captain::Tools::BasePublicTool
  description 'Create a company for the current conversation contact'
  param :name, type: 'string', desc: 'Company name', required: true
  param :domain, type: 'string', desc: 'Company domain', required: false
  param :description, type: 'string', desc: 'Company description', required: false

  def perform(tool_context, name:, domain: nil, description: nil)
    company = operations(tool_context.state).create_company_for_current_contact(
      name: name,
      domain: domain,
      description: description
    )

    "Created company #{company.name} (ID: #{company.id}) for the current contact"
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def operations(state)
    Captain::Tools::Operations::ContactOperations.new(
      assistant: assistant,
      conversation: current_conversation(state)
    )
  end
end
