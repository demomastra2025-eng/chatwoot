class Captain::Tools::Copilot::CreateDealService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_deal'
  end

  description 'Create a CRM deal from the current conversation context. Use list_deal_pipelines/list_deal_stages first when a specific pipeline or stage is needed.'
  param :title, type: :string, desc: 'Deal title', required: true
  param :description, type: :string, desc: 'Deal description', required: false
  param :pipeline_id, type: :number, desc: 'Pipeline ID from list_deal_pipelines; optional, defaults to account default pipeline', required: false
  param :pipeline_code, type: :string, desc: 'Pipeline code from list_deal_pipelines; optional alternative to pipeline_id', required: false
  param :stage_id, type: :number, desc: 'Stage ID from list_deal_stages/list_deal_pipelines; preferred when selecting a stage', required: false
  param :stage_name, type: :string, desc: 'Stage name; only use with pipeline_id/pipeline_code if names repeat', required: false
  param :stage_code, type: :string, desc: 'Stage code; only use with pipeline_id/pipeline_code if codes repeat', required: false
  param :amount,
        type: :string,
        desc: 'Deal amount as a whole number in major currency units. Use 200 for 200 KZT; do not multiply by 100. Decimal zero forms like 200.00 are accepted; fractional amounts like 200.50 are rejected.',
        required: false
  param :currency, type: :string, desc: 'ISO currency code', required: false
  param :expected_close_on, type: :string, desc: 'Expected close date in YYYY-MM-DD format', required: false
  param :win_probability, type: :number, desc: 'Win probability from 0 to 100', required: false
  param :custom_attributes, type: :object, desc: 'Optional custom attributes object', required: false

  def execute(title:, description: nil, amount: nil, currency: nil, expected_close_on: nil,
              win_probability: nil, custom_attributes: nil, pipeline_id: nil, pipeline_code: nil, stage_id: nil,
              stage_name: nil, stage_code: nil)
    deal = deal_operations.create_deal(
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
    formatted_record(deal)
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_deals') && user_has_permission('crm_deal_manage')
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
