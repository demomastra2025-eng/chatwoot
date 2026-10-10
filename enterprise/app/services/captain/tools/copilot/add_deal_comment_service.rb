class Captain::Tools::Copilot::AddDealCommentService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'add_deal_comment'
  end

  description 'Add a comment to a specific CRM deal returned by a prior tool'
  param :deal_id, type: :integer, desc: 'Verified deal ID; never infer a current deal', required: true
  param :body, type: :string, desc: 'Comment body', required: true

  def execute(body:, deal_id: nil)
    deal_id = required_positive_id(deal_id, field_name: 'deal_id')
    patient_scope&.require_id!(patient_scope.deals, deal_id, tool: self.class.name, kind: 'deal')
    comment = deal_operations(deal_id: deal_id).add_current_deal_comment(body: body)
    formatted_payload(
      action: 'add_deal_comment',
      deal_id: comment.commentable_id,
      comment: ::Crm::PayloadBuilder.comment(comment)
    )
  rescue Captain::Tools::Agent::PatientScope::Denied
    Captain::Tools::Agent::PatientScope::FAILURE
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_deals') && user_has_permission('crm_deal_manage')
  end

  private

  def deal_operations(deal_id:)
    Captain::Tools::Operations::DealOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user,
      deal_id: deal_id
    )
  end
end
