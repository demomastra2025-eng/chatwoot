class Integrations::Medelement::ProviderCommandReconciliationJob < MutexApplicationJob
  queue_as :medelement_provider_commands

  LOCK_TIMEOUT = 2.minutes

  retry_on LockAcquisitionError, wait: 15.seconds, attempts: 3

  def perform(command_id)
    command = Integrations::Medelement::ProviderCommand.includes(appointment: :resource).find_by(id: command_id)
    return if command.blank?

    with_command_locks(lock_keys(command)) do
      Integrations::Medelement::ProviderCommands::ReconciliationService.new(command: command).perform
    end
  end

  private

  def lock_keys(command)
    Integrations::Medelement::ProviderCommandJob.new.lock_keys(command)
  end

  def with_command_locks(keys, &)
    return yield if keys.empty?

    key, *remaining_keys = keys
    with_lock(key, LOCK_TIMEOUT) { with_command_locks(remaining_keys, &) }
  end
end
