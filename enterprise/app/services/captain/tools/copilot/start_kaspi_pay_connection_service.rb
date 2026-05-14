class Captain::Tools::Copilot::StartKaspiPayConnectionService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'start_kaspi_pay_connection'
  end

  description 'Start the administrator-only Kaspi Pay connection flow and return the process ID/view. Does not return tokens or secrets.'

  def execute
    formatted_kaspi_payload(kaspi_pay_operations.start_connection)
  end
end
