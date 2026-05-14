class Captain::Tools::Copilot::SyncKaspiPayPaymentStatusService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'sync_kaspi_pay_payment_status'
  end

  description 'Admin-only: ask Kaspi Pay for the latest status of a payment in the current account and update the local record'
  param :payment_id, type: :number, desc: 'Kaspi Pay payment database ID', required: true

  def execute(payment_id:)
    formatted_kaspi_payload(kaspi_pay_operations.sync_payment_status(payment_id: payment_id))
  end
end
