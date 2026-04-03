class Captain::Tools::Copilot::UpdateContactService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_contact'
  end

  description 'Update the current conversation contact'
  param :name, type: :string, desc: 'Updated contact name', required: false
  param :email, type: :string, desc: 'Updated contact email', required: false
  param :phone_number, type: :string, desc: 'Updated contact phone number', required: false
  param :identifier, type: :string, desc: 'Updated contact identifier', required: false
  param :custom_attributes_json, type: :string, desc: 'Optional custom attributes as JSON object', required: false

  def execute(name: nil, email: nil, phone_number: nil, identifier: nil, custom_attributes_json: nil)
    contact = contact_operations.update_current_contact(
      name: name,
      email: email,
      phone_number: phone_number,
      identifier: identifier,
      custom_attributes: custom_attributes_json
    )
    formatted_record(contact)
  rescue StandardError => e
    e.message
  end

  def active?
    current_contact.present? && user_has_permission('contact_manage')
  end

  private

  def contact_operations
    Captain::Tools::Operations::ContactOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end
end
