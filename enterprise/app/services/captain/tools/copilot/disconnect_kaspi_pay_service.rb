class Captain::Tools::Copilot::DisconnectKaspiPayService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'disconnect_kaspi_pay'
  end

  description 'Administrator-only action: disconnect Kaspi Pay from this account. Requires confirmation.'

  def execute
    formatted_kaspi_payload(kaspi_pay_operations.disconnect!)
  end
end
