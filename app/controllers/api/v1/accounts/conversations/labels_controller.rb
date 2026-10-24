class Api::V1::Accounts::Conversations::LabelsController < Api::V1::Accounts::Conversations::BaseController
  include LabelConcern

  private

  # A whole list from an older client was built from the labels of this conversation.
  def visible_labels
    @conversation.label_list
  end

  def change_labels(add:, remove:)
    Labels::UnifiedAssignmentService.new(
      contact: @conversation.contact,
      conversation: @conversation,
      add: add,
      remove: remove
    ).perform
    @conversation.reload
    @conversation.contact.reload
  end

  def current_label_list
    Labels::UnifiedAssignmentService.union_for(contact: @conversation.contact, conversations: [@conversation])
  end

  def permitted_params
    params.permit(:conversation_id, labels: [], add: [], remove: [])
  end
end
