# The labels of a person: the contact card shows and changes the same labels as the dialog, which means the labels of the
# contact and of all its conversations (Labels::UnifiedAssignmentService).
class Api::V1::Accounts::Contacts::LabelsController < Api::V1::Accounts::Contacts::BaseController
  include LabelConcern

  private

  # A whole list from an older client was built from the card's own labels, so it can only remove those.
  def visible_labels
    @contact.label_list
  end

  def change_labels(add:, remove:)
    Labels::UnifiedAssignmentService.new(contact: @contact, add: add, remove: remove).perform
  end

  def current_label_list
    Labels::UnifiedAssignmentService.person_labels(contact_id: @contact.id, account_id: @contact.account_id)
  end

  def permitted_params
    params.permit(labels: [], add: [], remove: [])
  end
end
