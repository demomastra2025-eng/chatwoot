class Captain::Tools::UpdateDealTool < Captain::Tools::BasePublicTool
  description 'Update a CRM deal by deal_id or the deal linked to the current conversation. ' \
              'Use list_deal_pipelines/list_deal_stages before changing pipeline or stage.'
  param :deal_id,
        type: 'integer',
        desc: 'Optional CRM deal ID to update. Use the ID returned by get_deal/search_deals when updating a specific deal; ' \
              'omit for the current conversation deal.',
        required: false
  param :title, type: 'string', desc: 'Updated deal title', required: false
  param :description, type: 'string', desc: 'Updated deal description', required: false
  param :pipeline_id,
        type: 'integer',
        desc: 'Positive pipeline ID for moving the deal. Omit when unknown; usually pair with stage_id.',
        required: false
  param :pipeline_code, type: 'string', desc: 'Pipeline code for moving the deal; optional alternative to pipeline_id', required: false
  param :stage_id, type: 'integer', desc: 'Positive target stage ID from list_deal_stages/list_deal_pipelines. Omit when unknown.', required: false
  param :stage_name, type: 'string', desc: 'Target stage name; only use with pipeline_id/pipeline_code if names repeat', required: false
  param :stage_code, type: 'string', desc: 'Target stage code; only use with pipeline_id/pipeline_code if codes repeat', required: false
  param :closing_reasons,
        type: 'array',
        desc: 'Configured closing reason labels when moving to a Won/Lost stage',
        required: false
  param :amount,
        type: 'string',
        desc: 'Updated amount as a whole number in major currency units. Use 200 for 200 KZT; do not multiply by 100. ' \
              'Decimal zero forms like 200.00 are accepted; fractional amounts like 200.50 are rejected.',
        required: false
  param :currency, type: 'string', desc: 'Updated ISO currency code', required: false
  param :expected_close_on, type: 'string', desc: 'Updated close date in YYYY-MM-DD format', required: false
  param :win_probability, type: 'number', desc: 'Updated win probability from 0 to 100', required: false
  param :custom_attributes,
        type: 'string',
        desc: 'JSON object string for CRM custom attributes. Use the matching list_*_custom_fields tool first; ' \
              'only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  def perform(tool_context, deal_id: nil, title: nil, description: nil, amount: nil, currency: nil,
              expected_close_on: nil, win_probability: nil, custom_attributes: nil, pipeline_id: nil,
              pipeline_code: nil, stage_id: nil, stage_name: nil, stage_code: nil, closing_reasons: nil)
    deal = operations(tool_context.state).update_current_deal(
      deal_id: deal_id,
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
      stage_code: stage_code,
      closing_reasons: closing_reasons
    )

    JSON.pretty_generate(::Crm::ToolPayloadBuilder.deal_payload(action: 'update_deal', deal: deal))
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
