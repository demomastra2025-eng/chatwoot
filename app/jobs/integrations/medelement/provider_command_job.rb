class Integrations::Medelement::ProviderCommandJob < MutexApplicationJob
  # New web processes enqueue v2 snapshots here. Legacy worker images do not poll this queue,
  # so a worker rollback cannot consume a request shape it does not fully understand.
  queue_as :medelement_provider_commands

  LOCK_TIMEOUT = 2.minutes

  retry_on LockAcquisitionError, wait: 15.seconds, attempts: 3

  def perform(command_id)
    command = Integrations::Medelement::ProviderCommand.includes(appointment: :resource).find_by(id: command_id)
    return if command.blank?

    with_command_locks(lock_keys(command)) do
      Integrations::Medelement::ProviderCommands::Executor.new(command: command).perform
    end
  end

  def lock_keys(command)
    target_ids = []
    target_ids << "contact-#{command.contact_id}" if command.contact_id
    resource_id = command.request_snapshot.to_h.dig('reception', 'resource_id') || command.appointment&.resource_id
    target_ids << resource_id.to_s if resource_id

    target_ids.uniq.map do |target_id|
      format(Redis::RedisKeys::MEDELEMENT_PROVIDER_COMMAND_MUTEX, hook_id: command.hook_id, target_id: target_id)
    end.sort
  end

  private

  def with_command_locks(keys, &)
    return yield if keys.empty?

    key, *remaining_keys = keys
    with_lock(key, LOCK_TIMEOUT) { with_command_locks(remaining_keys, &) }
  end
end
