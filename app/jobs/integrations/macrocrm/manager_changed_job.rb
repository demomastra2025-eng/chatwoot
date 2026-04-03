class Integrations::Macrocrm::ManagerChangedJob < MutexApplicationJob
  queue_as :medium
  LOCK_TIMEOUT = 30.seconds

  retry_on LockAcquisitionError, wait: 5.seconds, attempts: 12
  retry_on StandardError, wait: 10.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(hook_id, payload)
    with_lock(lock_key(hook_id), LOCK_TIMEOUT) do
      hook = Integrations::Hook.find(hook_id)

      Integrations::Macrocrm::ManagerChangedProcessorService.new(
        hook: hook,
        payload: payload.deep_stringify_keys
      ).perform
    end
  end

  private

  def lock_key(hook_id)
    format(::Redis::Alfred::CRM_PROCESS_MUTEX, hook_id: hook_id)
  end
end
