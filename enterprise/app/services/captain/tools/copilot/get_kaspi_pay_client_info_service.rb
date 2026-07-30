class Captain::Tools::Copilot::GetKaspiPayClientInfoService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'get_kaspi_pay_client_info'
  end

  description 'Admin-only: verify whether a phone number is available for a Kaspi Pay remote invoice'
  param :phone_number, type: :string, desc: 'Customer phone number containing 10 or 11 digits', required: true

  def execute(phone_number:)
    formatted_kaspi_payload(kaspi_pay_operations.client_info(phone_number: phone_number))
  end
end
