class Captain::Tools::Copilot::GetContactService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_contact'
  end

  description 'Get details of a contact including profile information'
  param :contact_id, type: :number, desc: 'The ID of the contact to retrieve', required: true

  def execute(contact_id:)
    contact = account.contacts.includes(:company).find_by(id: contact_id)
    return 'Contact not found' if contact.nil?

    formatted_payload(contact: contact_payload(contact))
  end

  def active?
    user_has_permission('contact_manage')
  end

  private

  def contact_payload(contact)
    {
      id: contact.id,
      name: contact.name,
      email: contact.email,
      phone_number: contact.phone_number,
      identifier: contact.identifier,
      company_id: contact.company_id,
      company_name: contact.company&.name,
      contact_type: contact.contact_type,
      blocked: contact.blocked,
      additional_attributes: contact.additional_attributes,
      custom_attributes: contact.custom_attributes,
      created_at: contact.created_at&.iso8601,
      updated_at: contact.updated_at&.iso8601,
      last_activity_at: contact.last_activity_at&.iso8601
    }
  end
end
