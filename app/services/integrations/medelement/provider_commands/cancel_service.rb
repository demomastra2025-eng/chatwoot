class Integrations::Medelement::ProviderCommands::CancelService
  def initialize(command:, actor:, now: Time.current)
    @command = command
    @actor = actor
    @now = now
  end

  def perform
    command.with_lock do
      command.reload
      next if command.cancelled?

      validate_cancellable!
      command.update!(cancelled_attributes)
    end

    command
  end

  private

  attr_reader :actor, :command, :now

  def validate_cancellable!
    return if command.reconciliation_required? || command.logical_status.start_with?('awaiting_patient_') || command.awaiting_phone_refresh?

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_COMMAND_NOT_CANCELLABLE',
      message: 'Only a command awaiting manual reconciliation can be cancelled',
      status: :conflict
    )
  end

  def cancelled_attributes
    {
      status: 'cancelled',
      executed_at: now,
      last_error_code: 'reconciliation_cancelled_manually',
      last_error_status: nil,
      execution_state: command.execution_state.to_h
                              .except('reconciliation_next_at')
                              .merge(
                                'reconciliation_cancelled_at' => now.iso8601,
                                'reconciliation_cancelled_by_id' => actor.id
                              )
    }
  end
end
