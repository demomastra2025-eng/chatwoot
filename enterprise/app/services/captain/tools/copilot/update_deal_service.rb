class Captain::Tools::Copilot::UpdateDealService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_deal'
  end

  description 'Update the CRM deal linked to the current conversation'
  param :title, type: :string, desc: 'Updated deal title', required: false
  param :description, type: :string, desc: 'Updated deal description', required: false
  param :amount_minor, type: :number, desc: 'Updated amount in minor currency units', required: false
  param :currency, type: :string, desc: 'Updated ISO currency code', required: false
  param :expected_close_on, type: :string, desc: 'Updated close date in YYYY-MM-DD format', required: false
  param :win_probability, type: :number, desc: 'Updated win probability from 0 to 100', required: false
  param :custom_attributes_json, type: :string, desc: 'Optional custom attributes as JSON object', required: false

  def execute(title: nil, description: nil, amount_minor: nil, currency: nil, expected_close_on: nil, win_probability: nil, custom_attributes_json: nil)
    deal = deal_operations.update_current_deal(
      title: title,
      description: description,
      amount_minor: amount_minor,
      currency: currency,
      expected_close_on: expected_close_on,
      win_probability: win_probability,
      custom_attributes: custom_attributes_json
    )
    formatted_record(deal)
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
