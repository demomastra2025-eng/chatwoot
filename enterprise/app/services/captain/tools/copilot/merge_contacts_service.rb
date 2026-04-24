class Captain::Tools::Copilot::MergeContactsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'merge_contacts'
  end

  description 'Merge one contact into another contact in the same account'
  param :base_contact_id, type: :integer, desc: 'Contact ID that should remain after the merge', required: true
  param :mergee_contact_id, type: :integer, desc: 'Contact ID that should be merged into the base contact and removed', required: true

  def execute(base_contact_id:, mergee_contact_id:)
    contact = contact_operations.merge_contacts(base_contact_id: base_contact_id, mergee_contact_id: mergee_contact_id)

    formatted_payload(
      action: 'merge_contacts',
      contact: {
        id: contact.id,
        name: contact.name,
        email: contact.email,
        phone_number: contact.phone_number,
        identifier: contact.identifier,
        company_id: contact.company_id,
        updated_at: contact.updated_at&.iso8601
      }
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
      conversation: current_conversation,
      actor: @user
    )
  end
end
