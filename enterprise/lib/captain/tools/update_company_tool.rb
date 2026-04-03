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

    "Updated company #{company.name} (ID: #{company.id})"
  rescue StandardError => e
    e.message
  end

  private

  def operations(state)
    Captain::Tools::Operations::ContactOperations.new(
      assistant: assistant,
      conversation: current_conversation(state)
    )
  end
end
