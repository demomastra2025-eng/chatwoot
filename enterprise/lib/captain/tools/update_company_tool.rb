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

    JSON.pretty_generate(::Crm::ToolPayloadBuilder.company_payload(action: 'update_company', company: company))
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
