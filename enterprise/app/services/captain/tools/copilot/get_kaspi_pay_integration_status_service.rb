class Captain::Tools::Copilot::GetKaspiPayIntegrationStatusService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'get_kaspi_pay_integration_status'
  end

  description 'Check local Kaspi Pay connection and optionally verify the live provider session without returning tokens or secrets.'
  param :live_check,
        type: :boolean,
        desc: 'Refresh and verify the provider session. Defaults to false because this rotates stored session credentials.',
        required: false

  def execute(live_check: false)
    formatted_kaspi_payload(kaspi_pay_operations.integration_status(live_check: live_check))
  end
end
