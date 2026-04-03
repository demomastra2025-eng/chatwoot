class Captain::Tools::UpdateContactTool < Captain::Tools::BasePublicTool
  description 'Update the current conversation contact'
  param :name, type: 'string', desc: 'Updated contact name', required: false
  param :email, type: 'string', desc: 'Updated contact email', required: false
  param :phone_number, type: 'string', desc: 'Updated contact phone number in E.164 format', required: false
  param :identifier, type: 'string', desc: 'Updated contact identifier', required: false
  param :custom_attributes_json, type: 'string', desc: 'Optional custom attributes as JSON object', required: false

  def perform(tool_context, name: nil, email: nil, phone_number: nil, identifier: nil, custom_attributes_json: nil)
    contact = operations(tool_context.state).update_current_contact(
      name: name,
      email: email,
      phone_number: phone_number,
      identifier: identifier,
      custom_attributes: custom_attributes_json
    )

    "Updated contact #{contact.name} (ID: #{contact.id})"
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
