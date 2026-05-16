class Captain::Tools::Copilot::RefundKaspiPayPaymentService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'refund_kaspi_pay_payment'
  end

  description 'Admin-only: request a Kaspi Pay refund for an account payment by payment ID and amount in KZT'
  param :payment_id, type: :number, desc: 'Kaspi Pay payment database ID', required: true
  param :amount, type: :number, desc: 'Refund amount as a whole number in KZT', required: true

  def execute(payment_id:, amount:)
    formatted_kaspi_payload(kaspi_pay_operations.refund_payment(payment_id: payment_id, amount: amount))
  end
end
