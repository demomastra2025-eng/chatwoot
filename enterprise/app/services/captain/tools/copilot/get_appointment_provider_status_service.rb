class Captain::Tools::Copilot::GetAppointmentProviderStatusService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_appointment_provider_status'
  end

  description 'Get the current MedElement provider outcome for the exact command returned by an appointment mutation'
  param :provider_command_id, type: :number, desc: 'Provider command ID returned by the mutation tool', required: true

  def execute(provider_command_id:)
    command = Integrations::Medelement::ProviderCommand.where(account_id: account.id).find(
      required_positive_id(provider_command_id, field_name: 'provider_command_id')
    )
    formatted_payload(
      provider_command_receipt: Integrations::Medelement::ProviderCommandReceiptBuilder.build(command: command)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end
end
