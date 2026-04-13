class Captain::Tools::CreateDealTool < Captain::Tools::BasePublicTool
  description 'Create a CRM deal from the current conversation context'
  param :title, type: 'string', desc: 'Deal title', required: true
  param :description, type: 'string', desc: 'Deal description', required: false
  param :amount_minor, type: 'number', desc: 'Deal amount in minor currency units', required: false
  param :currency, type: 'string', desc: 'ISO currency code', required: false
  param :expected_close_on, type: 'string', desc: 'Expected close date in YYYY-MM-DD format', required: false
  param :win_probability, type: 'number', desc: 'Win probability from 0 to 100', required: false
  param :custom_attributes_json, type: 'string', desc: 'Optional custom attributes as JSON object', required: false

  def perform(tool_context, title:, description: nil, amount_minor: nil, currency: nil, expected_close_on: nil, win_probability: nil, custom_attributes_json: nil)
    deal = operations(tool_context.state).create_deal(
      title: title,
      description: description,
      amount_minor: amount_minor,
      currency: currency,
      expected_close_on: expected_close_on,
      win_probability: win_probability,
      custom_attributes: custom_attributes_json
    )

    "Created deal #{deal.title} (ID: #{deal.id})"
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
