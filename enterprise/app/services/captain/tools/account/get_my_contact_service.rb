class Captain::Tools::Account::GetMyContactService < Captain::Tools::Account::BaseAccountTool
  def self.name
    'get_my_contact'
  end

  description 'Read the current conversation contact profile'

  def execute
    contact = patient_scope&.contacts&.first || (current_contact unless patient_scope)
    return formatted_payload(success: false, reason: 'not_found') if contact.blank?

    formatted_payload(success: true, contact: self.class.payload(contact))
  end

  def active?
    user_has_permission('contact_manage')
  end

  def self.payload(contact)
    custom = contact.custom_attributes.to_h
    iin = [contact.identifier, custom['iin']].find { |value| Scheduling::IinValidator.valid?(value) }
    iin = Scheduling::IinValidator.normalize(iin) if iin.present?
    {
      id: contact.id, first_name: contact.name, last_name: contact.last_name,
      middle_name: contact.middle_name, iin: iin,
      birth_date: custom['birth_date'], gender: custom['gender'],
      phone_number: contact.phone_number, email: contact.email
    }
  end
end
