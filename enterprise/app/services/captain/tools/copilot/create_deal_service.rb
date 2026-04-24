class Captain::Tools::Copilot::CreateDealService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_deal'
  end

  description 'Create a CRM deal from the current conversation context'
  param :title, type: :string, desc: 'Deal title', required: true
  param :description, type: :string, desc: 'Deal description', required: false
  param :amount_minor, type: :number, desc: 'Deal amount in minor currency units', required: false
  param :currency, type: :string, desc: 'ISO currency code', required: false
  param :expected_close_on, type: :string, desc: 'Expected close date in YYYY-MM-DD format', required: false
  param :win_probability, type: :number, desc: 'Win probability from 0 to 100', required: false
  param :custom_attributes, type: :object, desc: 'Optional custom attributes object', required: false

  def execute(title:, description: nil, amount_minor: nil, currency: nil, expected_close_on: nil, win_probability: nil, custom_attributes: nil)
    deal = deal_operations.create_deal(
      title: title,
      description: description,
      amount_minor: amount_minor,
      currency: currency,
      expected_close_on: expected_close_on,
      win_probability: win_probability,
      custom_attributes: custom_attributes
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
