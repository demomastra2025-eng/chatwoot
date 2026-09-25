class Integrations::Medelement::ProviderCommandJob < MutexApplicationJob
  # Old images poll medelement_provider_commands, but cannot safely execute a
  # Captain-originated command. Only the new dedicated worker polls this queue.
  queue_as :medelement_provider_commands_v2

  LOCK_TIMEOUT = 2.minutes

  retry_on LockAcquisitionError, wait: 15.seconds, attempts: 3

  def perform(command_id)
    command = Integrations::Medelement::ProviderCommand.includes(appointment: :resource).find_by(id: command_id)
    return if command.blank?

    with_command_locks(lock_keys(command)) do
      origin = command.execution_state.to_h['captain_action_origin'].to_h
      if origin.present?
        run_originated_command(command, origin)
      else
        Integrations::Medelement::ProviderCommands::Executor.new(command: command).perform
      end
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

  def run_originated_command(command, origin)
    state = {
      account_id: command.account_id,
      conversation: { id: origin['conversation_id'] },
      captain_control_generation: origin['control_generation']
    }
    assistant = Captain::Assistant.find_by(id: origin['assistant_id'])
    fence = Captain::Conversation::ActionFenceService.new(assistant: assistant, state: state)
    # MedElement has no proven provider-side idempotency/ordering contract for
    # Captain writes. A local intent alone cannot prevent a late remote effect
    # after takeover. Refuse the queued write before any provider request;
    # non-Captain commands retain their existing executor path.
    fence.with_effect! do
      command.with_lock do
        next unless command.queued?

        command.update!(status: 'cancelled', executed_at: Time.current,
                        last_error_code: 'captain_provider_contract_unavailable')
      end
    end
  rescue Captain::Conversation::ControlGenerationStaleError
    command.with_lock do
      next unless command.queued?

      command.update!(status: 'cancelled', last_error_code: 'captain_control_stale')
    end
  end

  def with_command_locks(keys, &)
    return yield if keys.empty?

    key, *remaining_keys = keys
    with_lock(key, LOCK_TIMEOUT) { with_command_locks(remaining_keys, &) }
  end
end
