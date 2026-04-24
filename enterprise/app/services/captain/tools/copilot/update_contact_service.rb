class Captain::Tools::Copilot::UpdateContactService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_contact'
  end

  description 'Update the current conversation contact'
  param :name, type: :string, desc: 'Updated contact name', required: false
  param :email, type: :string, desc: 'Updated contact email', required: false
  param :phone_number, type: :string, desc: 'Updated contact phone number in E.164 format', required: false
  param :identifier, type: :string, desc: 'Updated contact identifier', required: false
  param :custom_attributes, type: :object, desc: 'Optional custom attributes object', required: false

  def execute(name: nil, email: nil, phone_number: nil, identifier: nil, custom_attributes: nil)
    contact = contact_operations.update_current_contact(
      name: name,
      email: email,
      phone_number: phone_number,
      identifier: identifier,
      custom_attributes: custom_attributes
    )
    formatted_record(contact)
  rescue StandardError => e
    tool_failure(e)
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
