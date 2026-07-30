class Captain::Tools::CreateKaspiPayPaymentTool < Captain::Tools::BasePublicTool
  description 'Create a Kaspi Pay QR payment for the current customer conversation and deliver a native payment link or QR image'
  param :amount,
        type: 'number',
        desc: 'Payment amount as a whole number in KZT. Required unless the current appointment has a remaining ' \
              'amount. Use 15000 for 15000 KZT; do not multiply by 100.',
        required: false
  param :idempotency_key,
        type: 'string',
        desc: 'Optional stable key only when retrying the same exact payment request; omit to use the current ' \
              'incoming message as the stable retry boundary.',
        required: false
  param :delivery_mode,
        type: 'string',
        desc: 'Native customer delivery: link (default) or qr_image. Use qr_image when the customer asks for a QR code image.',
        required: false

  def perform(tool_context, amount: nil, idempotency_key: nil, delivery_mode: 'link')
    payload = operations(tool_context.state).create_current_conversation_payment(
      amount: amount,
      idempotency_key: idempotency_key,
      delivery_mode: delivery_mode
    )

    JSON.pretty_generate(payload.as_json)
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def operations(state)
    Captain::Tools::Operations::KaspiPayOperations.new(
      assistant: assistant,
      conversation: current_conversation(state),
      actor: assistant
    )
  end
end
