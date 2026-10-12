# Takes back a command that has not touched MedElement. The AI agent's tool that started it gave up waiting and reported a
# failure, so the conversation is on its way to a human: a command still waiting in the queue must not book, move or cancel
# afterwards, behind the back of the person who now handles the case (who would redo it by hand and duplicate it).
# A command that already started (it is being processed, or a write phase or reference is recorded) is left alone: its result
# is unknown, not absent.
class Integrations::Medelement::ProviderCommands::UnstartedWithdrawal
  WITHDRAWABLE_STATUSES = %w[queued awaiting_confirmation].freeze

  def initialize(command:, reason: 'agent_wait_timeout')
    @command = command
    @reason = reason
  end

  # True when this call withdrew the command.
  def perform
    withdrawn = command.with_lock do
      next false unless withdrawable?

      command.update!(status: 'cancelled', last_error_code: reason, executed_at: Time.current)
      Integrations::Medelement::AppointmentProviderStatus.persist_failed_command!(command)
      true
    end
    expire_confirmation! if withdrawn
    withdrawn
  end

  private

  attr_reader :command, :reason

  def withdrawable?
    command.logical_status.in?(WITHDRAWABLE_STATUSES) && !write_recorded?
  end

  # The executor publishes the write phase before it sends anything, so a recorded phase or write result means the request
  # may have gone out. The command's own reception code does not: a move or removal carries the code of the reception it is
  # about from the start.
  def write_recorded?
    command.execution_state.to_h.slice('write_phase', 'write_provider_patient_code', 'write_provider_reception_code').values.any?(&:present?)
  end

  def expire_confirmation!
    confirmation = command.confirmation_request
    return if confirmation.blank?

    confirmation.with_lock do
      next unless confirmation.pending?

      confirmation.update!(
        status: 'expired', resolved_at: Time.current, resolution_source: 'system',
        resolution_metadata: confirmation.resolution_metadata.to_h.merge('reason' => reason)
      )
    end
  end
end
