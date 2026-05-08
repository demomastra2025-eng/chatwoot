class Captain::Tools::UpdateDealTool < Captain::Tools::BasePublicTool
  description 'Update the CRM deal linked to the current conversation. Use list_deal_pipelines/list_deal_stages before changing pipeline or stage.'
  param :title, type: 'string', desc: 'Updated deal title', required: false
  param :description, type: 'string', desc: 'Updated deal description', required: false
  param :pipeline_id, type: 'number', desc: 'Pipeline ID for moving the deal; usually pair with stage_id', required: false
  param :pipeline_code, type: 'string', desc: 'Pipeline code for moving the deal; optional alternative to pipeline_id', required: false
  param :stage_id, type: 'number', desc: 'Target stage ID from list_deal_stages/list_deal_pipelines', required: false
  param :stage_name, type: 'string', desc: 'Target stage name; only use with pipeline_id/pipeline_code if names repeat', required: false
  param :stage_code, type: 'string', desc: 'Target stage code; only use with pipeline_id/pipeline_code if codes repeat', required: false
  param :amount,
        type: 'string',
        desc: 'Updated amount as a whole number in major currency units. Use 200 for 200 KZT; do not multiply by 100. Decimal zero forms like 200.00 are accepted; fractional amounts like 200.50 are rejected.',
        required: false
  param :currency, type: 'string', desc: 'Updated ISO currency code', required: false
  param :expected_close_on, type: 'string', desc: 'Updated close date in YYYY-MM-DD format', required: false
  param :win_probability, type: 'number', desc: 'Updated win probability from 0 to 100', required: false
  param :custom_attributes, type: 'object', desc: 'Optional custom attributes object', required: false

  def perform(tool_context, title: nil, description: nil, amount: nil, currency: nil,
              expected_close_on: nil, win_probability: nil, custom_attributes: nil, pipeline_id: nil,
              pipeline_code: nil, stage_id: nil, stage_name: nil, stage_code: nil)
    deal = operations(tool_context.state).update_current_deal(
      title: title,
      description: description,
      amount: amount,
      currency: currency,
      expected_close_on: expected_close_on,
      win_probability: win_probability,
      custom_attributes: custom_attributes,
      pipeline_id: pipeline_id,
      pipeline_code: pipeline_code,
      stage_id: stage_id,
      stage_name: stage_name,
      stage_code: stage_code
    )

    JSON.pretty_generate(
      action: 'update_deal',
      deal: ::Crm::PayloadBuilder.ai_deal(deal)
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
