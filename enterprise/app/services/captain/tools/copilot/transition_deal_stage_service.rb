class Captain::Tools::Copilot::TransitionDealStageService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'transition_deal_stage'
  end

  description 'Move a specific CRM deal. Use its deal_id from get_deal/search_deals; use list_deal_stages first and prefer stage_id; ' \
              'stage_action next/previous follows current pipeline position. For Won/Lost stages pass configured ' \
              'closing_reasons when required or known. For open stages pass configured transition_reason when required or known.'
  param :deal_id, type: :integer, desc: 'Specific deal ID from get_deal/search_deals', required: true
  param :stage_id, type: :integer, desc: 'Positive target stage ID from list_deal_stages/list_deal_pipelines. Omit when unknown.', required: false
  param :stage_name, type: :string, desc: 'Target stage name; scoped to the current deal pipeline unless pipeline_id/pipeline_code is provided',
                     required: false
  param :stage_code, type: :string, desc: 'Target stage code; scoped to the current deal pipeline unless pipeline_id/pipeline_code is provided',
                     required: false
  param :pipeline_id,
        type: :integer,
        desc: 'Positive pipeline ID used to scope stage_name/stage_code or move to that pipeline first active stage. Omit when unknown.',
        required: false
  param :pipeline_code, type: :string, desc: 'Pipeline code used to scope stage_name/stage_code or move to that pipeline first active stage',
                        required: false
  param :stage_action, type: :string, desc: 'Relative stage action: next or previous by position in the current pipeline', required: false
  param :closing_reasons,
        type: :array,
        desc: 'One or more configured closing reason labels from list_deal_stages for Won/Lost target stages',
        required: false
  param :transition_reason,
        type: :string,
        desc: 'Configured transition reason label from list_deal_stages for open target stages',
        required: false

  def execute(deal_id: nil, stage_id: nil, stage_name: nil, stage_code: nil, pipeline_id: nil, pipeline_code: nil, stage_action: nil,
              closing_reasons: nil, transition_reason: nil)
    formatted_payload(transition_deal_stage_payload(
                        deal_id: deal_id,
                        stage_id: stage_id, stage_name: stage_name, stage_code: stage_code, pipeline_id: pipeline_id,
                        pipeline_code: pipeline_code, stage_action: stage_action, closing_reasons: closing_reasons,
                        transition_reason: transition_reason
                      ))
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_deals') && user_has_permission('crm_deal_manage')
  end

  private

  def transition_deal_stage_payload(deal_id:, **attributes)
    deal_id = required_positive_id(deal_id, field_name: 'deal_id')
    scope = patient_scope ? patient_scope.deals : account.crm_deals
    previous_stage = scope.find(deal_id).stage
    deal = deal_operations(deal_id: deal_id).transition_current_deal_stage(**attributes)
    ::Crm::ToolPayloadBuilder.deal_transition_payload(action: 'transition_deal_stage', deal: deal, previous_stage: previous_stage)
  end

  def deal_operations(deal_id:)
    Captain::Tools::Operations::DealOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user,
      deal_id: deal_id
    )
  end
end
