class Integrations::Medelement::SyncJob < MutexApplicationJob
  queue_as :medium
  LOCK_TIMEOUT = 10.minutes

  retry_on LockAcquisitionError, wait: 30.seconds, attempts: 6
  retry_on Integrations::Medelement::Client::ApiError, wait: 1.minute, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(hook_id)
    hook = Integrations::Hook.find(hook_id)

    with_lock(lock_key(hook.account_id), LOCK_TIMEOUT) do
      hook.reload
      Integrations::Medelement::SyncCoordinatorService.new(hook: hook).perform
    end
  end

  private

  def lock_key(account_id)
    format(::Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account_id)
  end
end
