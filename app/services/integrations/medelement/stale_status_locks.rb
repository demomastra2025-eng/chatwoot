# The two locks of a stale status reconciliation: one run per hook at a time, and the account's sync mutex, taken for one
# import at a time only, so the regular sync and the delta poll are never kept waiting for more than a moment. A sync
# that holds the mutex for longer ends the run (the reason is the error message); the next run continues.
class Integrations::Medelement::StaleStatusLocks
  Unavailable = Class.new(StandardError)

  RUN_LEASE = 30.minutes
  SYNC_LEASE = 2.minutes
  SYNC_ATTEMPTS = 24
  SYNC_PAUSE_SECONDS = 5

  def initialize(hook:, sleeper:)
    @hook = hook
    @sleeper = sleeper
  end

  def hold_run
    @run_key = format(::Redis::Alfred::MEDELEMENT_STALE_STATUS_MUTEX, hook_id: hook.id)
    @run_lock = ::Redis::LockManager.new
    raise Unavailable, 'already_running' unless @run_lock.lock(@run_key, RUN_LEASE)

    begin
      yield
    ensure
      @run_lock.unlock(@run_key)
    end
  end

  def renew_run!
    raise Unavailable, 'lock_lost' unless @run_lock.renew(@run_key, RUN_LEASE)
  end

  def hold_sync
    key = format(::Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: hook.account_id)
    lock = ::Redis::LockManager.new
    wait_for(lock, key)

    begin
      yield
    ensure
      lock.unlock(key)
    end
  end

  private

  attr_reader :hook, :sleeper

  def wait_for(lock, key)
    attempts = 0
    until lock.lock(key, SYNC_LEASE)
      attempts += 1
      raise Unavailable, 'sync_busy' if attempts >= SYNC_ATTEMPTS

      sleeper.call(SYNC_PAUSE_SECONDS)
    end
  end
end
