class Captain::Tools::TransitionDealStageTool < Captain::Tools::BasePublicTool
  description 'Move the CRM deal linked to the current conversation to another stage'
  param :stage_id, type: 'number', desc: 'Target stage ID', required: false
  param :stage_name, type: 'string', desc: 'Target stage name', required: false
  param :stage_code, type: 'string', desc: 'Target stage code', required: false

  def perform(tool_context, stage_id: nil, stage_name: nil, stage_code: nil)
    deal = operations(tool_context.state).transition_current_deal_stage(
      stage_id: stage_id,
      stage_name: stage_name,
      stage_code: stage_code
    )

    JSON.pretty_generate(
      action: 'transition_deal_stage',
      deal: ::Crm::PayloadBuilder.deal(deal)
    )
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
