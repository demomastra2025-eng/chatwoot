class Captain::Tools::Copilot::SendKaspiPayPhoneService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'send_kaspi_pay_phone'
  end

  description 'Send the Kaspi cashier phone and return the next auth step; enter any requested password in integration settings, never in chat.'
  param :process_id, type: :string, desc: 'Kaspi Pay connection process ID returned by start_kaspi_pay_connection', required: true
  param :phone_number, type: :string, desc: 'Kaspi Pay cashier/POS operator phone number authorized for the merchant', required: true

  def execute(process_id:, phone_number:)
    formatted_kaspi_payload(kaspi_pay_operations.send_phone(process_id: process_id, phone_number: phone_number))
  end
end
