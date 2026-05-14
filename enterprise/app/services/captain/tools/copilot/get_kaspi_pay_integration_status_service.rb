class Captain::Tools::Copilot::GetKaspiPayIntegrationStatusService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'get_kaspi_pay_integration_status'
  end

  description 'Check whether Kaspi Pay is connected for this account. Does not return tokens or secrets.'

  def execute
    formatted_kaspi_payload(kaspi_pay_operations.integration_status)
  end
end
