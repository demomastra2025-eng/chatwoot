class Captain::Tools::Copilot::AddDealCommentService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'add_deal_comment'
  end

  description 'Add a comment to the CRM deal linked to the current conversation'
  param :body, type: :string, desc: 'Comment body', required: true

  def execute(body:)
    comment = deal_operations.add_current_deal_comment(body: body)
    formatted_payload(
      action: 'add_deal_comment',
      deal_id: comment.commentable_id,
      comment: ::Crm::PayloadBuilder.comment(comment)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    current_deal.present? && feature_enabled?('crm_deals') && user_has_permission('crm_deal_manage')
  end

  private

  def deal_operations
    Captain::Tools::Operations::DealOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end
end
