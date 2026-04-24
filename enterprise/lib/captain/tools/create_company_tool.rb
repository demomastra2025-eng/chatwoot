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

    JSON.pretty_generate(
      action: 'create_company',
      company: company_payload(company)
    )
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
