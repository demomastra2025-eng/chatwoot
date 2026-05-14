class Captain::Tools::Copilot::GetKaspiPayPaymentService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'get_kaspi_pay_payment'
  end

  description 'Admin-only: get one Kaspi Pay payment in the current account, optionally syncing its latest provider status first'
  param :payment_id, type: :number, desc: 'Kaspi Pay payment database ID', required: true
  param :sync, type: :boolean, desc: 'When true, asks Kaspi Pay for the latest status before returning', required: false

  def execute(payment_id:, sync: false)
    formatted_kaspi_payload(kaspi_pay_operations.get_payment(payment_id: payment_id, sync: sync))
  end
end
