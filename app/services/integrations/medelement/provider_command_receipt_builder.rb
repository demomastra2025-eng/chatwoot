class Integrations::Medelement::ProviderCommandReceiptBuilder
  LOOKUP_TOOL = 'get_appointment_provider_status'.freeze

  class << self
    def build(command:)
      return if command.blank?

      {
        appointment_id: command.appointment_id,
        expected_operation: command.operation,
        lookup_tool: LOOKUP_TOOL,
        linked: true,
        terminal: command.status.in?(Integrations::Medelement::ProviderCommand::TERMINAL_STATUSES),
        command: Integrations::Medelement::ProviderCommandPayloadBuilder.build(command)
      }
    end
  end
end
