class Integrations::Medelement::ProviderCommandJob < MutexApplicationJob
  queue_as :low

  LOCK_TIMEOUT = 2.minutes

  retry_on LockAcquisitionError, wait: 15.seconds, attempts: 3

  def perform(command_id)
    command = Integrations::Medelement::ProviderCommand.includes(appointment: :resource).find_by(id: command_id)
    return if command.blank?

    with_lock(lock_key(command), LOCK_TIMEOUT) do
      Integrations::Medelement::ProviderCommands::Executor.new(command: command).perform
    end
  end

  def lock_key(command)
    target_id = command.appointment&.resource_id || "contact-#{command.contact_id}"
    format(Redis::RedisKeys::MEDELEMENT_PROVIDER_COMMAND_MUTEX, hook_id: command.hook_id, target_id: target_id)
  end
end
