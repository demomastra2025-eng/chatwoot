class Captain::Tools::TransitionDealStageTool < Captain::Tools::BasePublicTool
  description 'Move the CRM deal linked to the current conversation. Use list_deal_stages first and prefer stage_id; stage_action next/previous follows current pipeline position.'
  param :stage_id, type: 'integer', desc: 'Positive target stage ID from list_deal_stages/list_deal_pipelines. Omit when unknown.', required: false
  param :stage_name, type: 'string', desc: 'Target stage name; scoped to the current deal pipeline unless pipeline_id/pipeline_code is provided',
                     required: false
  param :stage_code, type: 'string', desc: 'Target stage code; scoped to the current deal pipeline unless pipeline_id/pipeline_code is provided',
                     required: false
  param :pipeline_id, type: 'integer', desc: 'Positive pipeline ID used to scope stage_name/stage_code or move to that pipeline first active stage. Omit when unknown.',
                      required: false
  param :pipeline_code, type: 'string', desc: 'Pipeline code used to scope stage_name/stage_code or move to that pipeline first active stage',
                        required: false
  param :stage_action, type: 'string', desc: 'Relative stage action: next or previous by position in the current pipeline', required: false

  def perform(tool_context, stage_id: nil, stage_name: nil, stage_code: nil, pipeline_id: nil, pipeline_code: nil,
              stage_action: nil)
    deal = operations(tool_context.state).transition_current_deal_stage(
      stage_id: stage_id,
      stage_name: stage_name,
      stage_code: stage_code,
      pipeline_id: pipeline_id,
      pipeline_code: pipeline_code,
      stage_action: stage_action
    )

    JSON.pretty_generate(::Crm::ToolPayloadBuilder.deal_payload(action: 'transition_deal_stage', deal: deal))
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def operations(state)
    Captain::Tools::Operations::DealOperations.new(
      assistant: assistant,
      conversation: current_conversation(state)
    )
  end
end
