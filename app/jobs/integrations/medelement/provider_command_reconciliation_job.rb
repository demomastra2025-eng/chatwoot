class Integrations::Medelement::ProviderCommandReconciliationJob < MutexApplicationJob
  queue_as :medelement_provider_commands

  LOCK_TIMEOUT = 2.minutes

  retry_on LockAcquisitionError, wait: 15.seconds, attempts: 3

  def perform(command_id)
    command = Integrations::Medelement::ProviderCommand.includes(appointment: :resource).find_by(id: command_id)
    return if command.blank?
    return verify_create_receipt(command) if Integrations::Medelement::ProviderCommands::ReceptionReceiptVerificationService.applicable?(command)

    with_command_locks(lock_keys(command)) do
      Integrations::Medelement::ProviderCommands::ReconciliationService.new(command: command).perform
    end
  end

  private

  # The check of an accepted create only reads the provider and records its result on the command row (under that row's own
  # lock). It writes nothing to MedElement, so it never takes the contact and resource mutexes of real commands: a slow
  # provider must not hold them while a patient's next booking waits.
  def verify_create_receipt(command)
    Integrations::Medelement::ProviderCommands::ReceptionReceiptVerificationService.new(command: command).perform
  end

  def lock_keys(command)
    Integrations::Medelement::ProviderCommandJob.new.lock_keys(command)
  end

  def with_command_locks(keys, &)
    return yield if keys.empty?

    key, *remaining_keys = keys
    with_lock(key, LOCK_TIMEOUT) { with_command_locks(remaining_keys, &) }
  end
end
