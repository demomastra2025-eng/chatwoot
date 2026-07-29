class Integrations::Medelement::ProviderCommandReconciliationJob < MutexApplicationJob
  queue_as :low

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
    target_ids = []
    target_ids << "contact-#{command.contact_id}" if command.contact_id
    target_ids << command.appointment.resource_id.to_s if command.appointment&.resource_id

    target_ids.uniq.map do |target_id|
      format(Redis::RedisKeys::MEDELEMENT_PROVIDER_COMMAND_MUTEX, hook_id: command.hook_id, target_id: target_id)
    end.sort
  end

  def with_command_locks(keys, &)
    return yield if keys.empty?

    key, *remaining_keys = keys
    with_lock(key, LOCK_TIMEOUT) { with_command_locks(remaining_keys, &) }
  end
end
