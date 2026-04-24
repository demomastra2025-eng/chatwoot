class Captain::Tools::UpdateCompanyTool < Captain::Tools::BasePublicTool
  description 'Update the company linked to the current conversation contact'
  param :name, type: 'string', desc: 'Updated company name', required: false
  param :domain, type: 'string', desc: 'Updated company domain', required: false
  param :description, type: 'string', desc: 'Updated company description', required: false

  def perform(tool_context, name: nil, domain: nil, description: nil)
    company = operations(tool_context.state).update_current_company(
      name: name,
      domain: domain,
      description: description
    )

    JSON.pretty_generate(
      action: 'update_company',
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
