class Captain::Tools::Copilot::TransitionDealStageService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'transition_deal_stage'
  end

  description 'Move the CRM deal linked to the current conversation to another stage'
  param :stage_id, type: :number, desc: 'Target stage ID', required: false
  param :stage_name, type: :string, desc: 'Target stage name', required: false
  param :stage_code, type: :string, desc: 'Target stage code', required: false

  def execute(stage_id: nil, stage_name: nil, stage_code: nil)
    deal = deal_operations.transition_current_deal_stage(
      stage_id: stage_id,
      stage_name: stage_name,
      stage_code: stage_code
    )
    formatted_record(deal)
  rescue StandardError => e
    e.message
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
