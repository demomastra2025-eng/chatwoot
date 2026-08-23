class Integrations::Medelement::ProviderCommands::AutoConfirmationService
  METADATA = {
    'medelement_auto_sync' => true,
    'surface' => 'onelink_outbound_change'
  }.freeze

  def initialize(command:)
    @command = command
  end

  def perform
    return command unless command.awaiting_confirmation?

    Confirmations::ResolveService.new(
      account: command.account,
      confirmation_request: command.confirmation_request,
      decision: 'confirmed',
      source: 'system',
      actor: command.requested_by,
      metadata: METADATA
    ).perform
    command.reload
  end

  private

  attr_reader :command
end
