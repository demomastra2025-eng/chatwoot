class Captain::Tools::Copilot::CreateKaspiPayPaymentService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'create_kaspi_pay_payment'
  end

  description 'Create a Kaspi Pay QR payment link or remote invoice for an account conversation or appointment. Admin-only in assistant scope; customer-agent scope is limited to the current conversation QR flow.'
  param :amount,
        type: :number,
        desc: 'Payment amount as a whole number in KZT. Required unless appointment_id/current appointment has a remaining amount. Use 15000 for 15000 KZT; do not multiply by 100.',
        required: false
  param :conversation_id,
        type: :number,
        desc: 'Optional conversation display ID or database ID to attach the payment to. Omit when using appointment_id or the current conversation.',
        required: false
  param :appointment_id,
        type: :number,
        desc: 'Optional appointment database ID to attach the payment to and derive remaining amount from.',
        required: false
  param :payment_type,
        type: :string,
        desc: 'Payment type: qr or invoice. Use invoice only when sending a remote Kaspi Pay invoice to a known customer phone.',
        required: false
  param :phone_number,
        type: :string,
        desc: 'Customer phone number for invoice payments. Required when payment_type is invoice unless the source contact has a phone.',
        required: false
  param :comment,
        type: :string,
        desc: 'Optional invoice comment/order note shown in Kaspi Pay.',
        required: false
  param :idempotency_key,
        type: :string,
        desc: 'Optional stable key only when retrying the same exact payment request; omit for a new payment link.',
        required: false

  def execute(amount: nil, conversation_id: nil, appointment_id: nil, payment_type: nil, phone_number: nil, comment: nil, idempotency_key: nil)
    formatted_kaspi_payload(
      kaspi_pay_operations.create_account_payment(
        amount: amount,
        conversation_id: conversation_id,
        appointment_id: appointment_id,
        payment_type: payment_type.presence || 'qr',
        phone_number: phone_number,
        comment: comment,
        idempotency_key: idempotency_key
      )
    )
  end
end
