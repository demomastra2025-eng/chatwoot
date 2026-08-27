class Integrations::Medelement::CleanupJob < MutexApplicationJob
  queue_as :medelement_sync
  LOCK_TIMEOUT = 10.minutes

  retry_on LockAcquisitionError, wait: 30.seconds, attempts: 6
  discard_on ActiveRecord::RecordNotFound

  def perform(account_id)
    with_lock(lock_key(account_id), LOCK_TIMEOUT) do
      next if Integrations::Hook.exists?(account_id: account_id, app_id: 'medelement')

      account = Account.find(account_id)
      Integrations::Medelement::CleanupService.new(account: account).perform
    end
  end

  private

  def lock_key(account_id)
    format(::Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account_id)
  end
end
