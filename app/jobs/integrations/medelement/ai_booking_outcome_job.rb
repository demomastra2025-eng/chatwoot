# Retired. The AI agent talks only to the calendar and the calendar talks to MedElement: a MedElement outcome, early or
# late, never posts to a conversation, hands it off or changes its status. A late outcome only updates the appointment
# state in the calendar (see Integrations::Medelement::ProviderCommands::SuccessApplier and ReconciliationLifecycle).
# The class stays only so that jobs enqueued before the change drain without an error; it does nothing.
class Integrations::Medelement::AiBookingOutcomeJob < ApplicationJob
  queue_as :medelement_provider_commands

  def perform(_command_id); end
end
