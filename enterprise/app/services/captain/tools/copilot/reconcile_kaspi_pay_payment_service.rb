class Captain::Tools::Copilot::ReconcileKaspiPayPaymentService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'reconcile_kaspi_pay_payment'
  end

  description 'Admin-only: fetch Kaspi operation details and reconcile local payment/refund status'
  param :payment_id, type: :number, desc: 'Kaspi Pay payment database ID', required: true
  param :operation_method, type: :number, desc: 'Kaspi operation method from history/details. Defaults to 0.', required: false

  def execute(payment_id:, operation_method: 0)
    formatted_kaspi_payload(kaspi_pay_operations.reconcile_payment(payment_id: payment_id, operation_method: operation_method))
  end
end
