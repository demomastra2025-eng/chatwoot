class Integrations::Medelement::ProviderCommandJob < MutexApplicationJob
  LEGACY_QUEUE = 'medelement_provider_commands'.freeze
  VERSIONED_QUEUE = 'medelement_provider_commands_v2'.freeze

  # A rollback-era worker must never claim a v2 snapshot. New workers consume
  # both queues so pre-existing legacy receipts remain dispatchable.
  queue_as { self.class.queue_for(arguments.first) }

  def self.queue_for(command_id)
    status = Integrations::Medelement::ProviderCommand.where(id: command_id).pick(:status)
    status&.start_with?('v2_') ? VERSIONED_QUEUE : LEGACY_QUEUE
  end

  def self.queue_for_confirmation(confirmation_request_id)
    command_id = Integrations::Medelement::ProviderCommand.where(confirmation_request_id: confirmation_request_id).pick(:id)
    queue_for(command_id)
  end

  LOCK_TIMEOUT = 2.minutes

  retry_on LockAcquisitionError, wait: 15.seconds, attempts: 3

  def perform(command_id)
    command = Integrations::Medelement::ProviderCommand.includes(appointment: :resource).find_by(id: command_id)
    return if command.blank?

    with_command_locks(lock_keys(command)) do
      return if Captain::Conversation::ActionFenceService.cancel_pending!(command)
      # Human takeover may have cancelled it before this job was dequeued;
      # processing or unknown Captain effects belong to read-back, not to a
      # fresh Executor attempt. Direct Executor callers have the same fence.
      return if Captain::Conversation::ActionFenceService.captain_command?(command)

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
