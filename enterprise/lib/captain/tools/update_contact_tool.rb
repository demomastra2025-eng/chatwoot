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
      identifier: checked_identifier(identifier, custom_attributes),
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

  # The identifier of a patient of an account that identifies patients by an IIN is the IIN: 12 digits, never a phone number or any other text, also when it is
  # written as the iin of the custom attributes. The contacts of any other account keep the identifier as it is given.
  def checked_identifier(identifier, custom_attributes)
    return identifier unless Scheduling::IinValidator.in_use?(assistant.account)

    Scheduling::IinValidator.require_valid_in!(identifier: identifier, custom_attributes: custom_attributes)
  end

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
      identifier: Scheduling::IinValidator.tokenize_or_sanitize_identifier(contact.identifier),
      company_id: contact.company_id,
      contact_type: contact.contact_type,
      additional_attributes: Scheduling::IinValidator.tokenize_or_sanitize_custom_attributes(contact.additional_attributes),
      custom_attributes: Scheduling::IinValidator.tokenize_or_sanitize_custom_attributes(contact.custom_attributes),
      created_at: contact.created_at&.iso8601,
      updated_at: contact.updated_at&.iso8601
    }
  end
end
