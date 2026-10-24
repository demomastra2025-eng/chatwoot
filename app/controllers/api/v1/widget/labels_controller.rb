class Api::V1::Widget::LabelsController < Api::V1::Widget::BaseController
  def create
    if conversation.present? && label_defined_in_account?
      Labels::UnifiedAssignmentService.add(contact: conversation.contact, labels: [permitted_params[:label]], conversation: conversation)
    end

    head :no_content
  end

  def destroy
    if conversation.present?
      Labels::UnifiedAssignmentService.remove(contact: conversation.contact, labels: [permitted_params[:id]], conversation: conversation)
    end

    head :no_content
  end

  private

  def label_defined_in_account?
    label = @current_account.labels&.find_by(title: permitted_params[:label])
    label.present?
  end

  def permitted_params
    params.permit(:id, :label, :website_token)
  end
end
