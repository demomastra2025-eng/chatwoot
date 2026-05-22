class Captain::Tools::UpdateContactTool < Captain::Tools::BasePublicTool
  description 'Update the current conversation contact'
  param :name, type: 'string', desc: 'Updated contact name', required: false
  param :email, type: 'string', desc: 'Updated contact email', required: false
  param :phone_number, type: 'string', desc: 'Updated contact phone number in E.164 format', required: false
  param :identifier, type: 'string', desc: 'Updated contact identifier', required: false
  param :custom_attributes, type: 'object', desc: 'Optional custom attributes object', required: false

  def perform(tool_context, name: nil, email: nil, phone_number: nil, identifier: nil, custom_attributes: nil)
    contact = operations(tool_context.state).update_current_contact(
      name: name,
      email: email,
      phone_number: phone_number,
      identifier: identifier,
      custom_attributes: custom_attributes
    )

    JSON.pretty_generate(
      action: 'update_contact',
      contact: contact_payload(contact)
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

  def contact_payload(contact)
    {
      id: contact.id,
      name: contact.name,
      email: contact.email,
      phone_number: contact.phone_number,
      identifier: contact.identifier,
      company_id: contact.company_id,
      contact_type: contact.contact_type,
      additional_attributes: contact.additional_attributes,
      custom_attributes: contact.custom_attributes,
      created_at: contact.created_at&.iso8601,
      updated_at: contact.updated_at&.iso8601
    }
  end
end
