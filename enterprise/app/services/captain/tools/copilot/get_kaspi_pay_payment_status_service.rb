class Captain::Tools::Copilot::GetKaspiPayPaymentStatusService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'get_kaspi_pay_payment_status'
  end

  description 'Get or verify one Kaspi Pay payment status in the current account. Customer-agent scope is limited to the current conversation.'
  param :payment_id, type: :number, desc: 'Kaspi Pay payment database ID', required: true
  param :sync, type: :boolean, desc: 'When true, asks Kaspi Pay for the latest status before returning', required: false

  def execute(payment_id:, sync: false)
    formatted_kaspi_payload(kaspi_pay_operations.get_payment(payment_id: payment_id, sync: sync).merge(action: 'get_kaspi_pay_payment_status'))
  end
end
