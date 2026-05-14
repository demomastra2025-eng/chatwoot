class Captain::Tools::CreateKaspiPayPaymentTool < Captain::Tools::BasePublicTool
  description 'Create a Kaspi Pay QR payment link only for the current customer conversation or its linked appointment'
  param :amount,
        type: 'number',
        desc: 'Payment amount as a whole number in KZT. Required unless the current appointment has a remaining amount. Use 15000 for 15000 KZT; do not multiply by 100.',
        required: false
  param :idempotency_key,
        type: 'string',
        desc: 'Optional stable key only when retrying the same exact payment request; omit for a new payment link.',
        required: false

  def perform(tool_context, amount: nil, idempotency_key: nil)
    payload = operations(tool_context.state).create_current_conversation_payment(
      amount: amount,
      idempotency_key: idempotency_key
    )

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
