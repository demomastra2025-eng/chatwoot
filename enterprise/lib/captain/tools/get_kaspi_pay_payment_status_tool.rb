class Captain::Tools::GetKaspiPayPaymentStatusTool < Captain::Tools::BasePublicTool
  description 'Get or verify the Kaspi Pay status only for a payment linked to the current customer conversation or its linked appointment'
  param :payment_id,
        type: 'number',
        desc: 'Optional Kaspi Pay payment ID. If omitted, the latest payment for the current conversation or linked appointment is used.',
        required: false
  param :sync,
        type: 'boolean',
        desc: 'When true, asks Kaspi Pay for the latest status before returning. Only use when the customer asks to check payment.',
        required: false

  def perform(tool_context, payment_id: nil, sync: false)
    payload = operations(tool_context.state).current_payment_status(payment_id: payment_id, sync: sync)

    JSON.pretty_generate(payload.as_json)
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def operations(state)
    Captain::Tools::Operations::KaspiPayOperations.new(
      assistant: assistant,
      conversation: current_conversation(state)
    )
  end
end
