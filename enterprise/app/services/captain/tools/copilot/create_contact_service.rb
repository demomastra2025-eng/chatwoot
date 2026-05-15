class Captain::Tools::Copilot::CreateContactService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_contact'
  end

  description 'Create a new account contact by email, phone number, or identifier'
  param :name, type: :string, desc: 'Contact name', required: false
  param :email, type: :string, desc: 'Contact email', required: false
  param :phone_number, type: :string, desc: 'Contact phone number in E.164 format', required: false
  param :identifier, type: :string, desc: 'External contact identifier', required: false
  param :company_id, type: :number, desc: 'Optional account company ID to link', required: false
  param :custom_attributes, type: :object, desc: 'Optional custom attributes object', required: false
  param :additional_attributes, type: :object, desc: 'Optional additional attributes object', required: false

  def execute(**params)
    result = contact_operations.create_contact(params)

    formatted_payload(
      action: 'create_contact',
      status: result.fetch(:status),
      contact: contact_payload(result.fetch(:contact))
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    user_has_permission('contact_manage')
  end

  private

  def contact_operations
    Captain::Tools::Operations::ContactOperations.new(
      assistant: assistant,
      actor: @user
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
