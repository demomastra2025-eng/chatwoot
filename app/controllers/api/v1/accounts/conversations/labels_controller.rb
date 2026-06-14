class Api::V1::Accounts::Conversations::LabelsController < Api::V1::Accounts::Conversations::BaseController
  include LabelConcern

  private

  def model
    @model ||= @conversation
  end

  def update_label_list(labels)
    Labels::UnifiedAssignmentService.new(
      contact: @conversation.contact,
      conversations: [@conversation],
      labels: labels
    ).perform
  end

  def current_label_list
    Labels::UnifiedAssignmentService.union_for(
      contact: @conversation.contact,
      conversations: [@conversation]
    )
  end

  def permitted_params
    params.permit(:conversation_id, labels: [])
  end
end
