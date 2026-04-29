class Integrations::Macrocrm::SyncJob < MutexApplicationJob
  queue_as :medium
  LOCK_TIMEOUT = 30.seconds

  retry_on Integrations::Macrocrm::Client::TransientError, wait: 1.minute, attempts: 5
  retry_on LockAcquisitionError, wait: 5.seconds, attempts: 12
  discard_on ActiveRecord::RecordNotFound
  discard_on Integrations::Macrocrm::Client::PermanentError do |job, error|
    Rails.logger.warn(
      '[MACROCRM][SYNC] Dropping non-retryable MacroCRM failure: ' \
      "error_class=#{error.class} endpoint=#{error.try(:endpoint)} status=#{error.try(:status)} " \
      "hook_id=#{job.arguments[0]} event=#{job.arguments[1]} message_id=#{job.arguments[2]}"
    )
  end

  def perform(hook_id, event_name, message_id)
    message = Message.find(message_id)

    with_lock(lock_key(hook_id, message.conversation_id || "message-#{message_id}"), LOCK_TIMEOUT) do
      hook = Integrations::Hook.find(hook_id)

      Integrations::Macrocrm::ProcessorService.new(hook: hook, event_name: event_name, message: message).perform
    end
  end

  private

  def lock_key(hook_id, conversation_id)
    format(::Redis::Alfred::MACROCRM_SYNC_MUTEX, hook_id: hook_id, conversation_id: conversation_id)
  end
end
