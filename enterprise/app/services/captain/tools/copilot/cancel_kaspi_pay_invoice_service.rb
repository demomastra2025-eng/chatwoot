class Captain::Tools::Copilot::CancelKaspiPayInvoiceService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'cancel_kaspi_pay_invoice'
  end

  description 'Admin-only: cancel a pending Kaspi Pay remote invoice by local payment ID'
  param :payment_id, type: :number, desc: 'Kaspi Pay invoice database ID', required: true

  def execute(payment_id:)
    formatted_kaspi_payload(kaspi_pay_operations.cancel_invoice(payment_id: payment_id))
  end
end
