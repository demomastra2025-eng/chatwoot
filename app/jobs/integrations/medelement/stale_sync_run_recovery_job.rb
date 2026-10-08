class Integrations::Medelement::StaleSyncRunRecoveryJob < ApplicationJob
  queue_as :scheduled_jobs

  STALE_AFTER = 45.minutes
  ORPHANED_AFTER = 10.minutes
  StaleRunError = Class.new(StandardError)

  retry_on ActiveJob::EnqueueError, wait: 30.seconds, attempts: 24

  def perform
    Integrations::Medelement::SyncRun.active
                                      .where('created_at < :cutoff OR updated_at < :cutoff', cutoff: ORPHANED_AFTER.ago)
                                      .find_each do |candidate|
      recover(candidate)
    end
  end

  private

  def recover(candidate)
    lock_key = format(Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: candidate.account_id)
    lock_manager = Redis::LockManager.new
    return unless lock_manager.lock(lock_key, Integrations::Medelement::SyncJob::LOCK_TIMEOUT)

    recover_locked(candidate, lock_manager, lock_key)
  ensure
    lock_manager&.unlock(lock_key)
  end

  def recover_locked(candidate, lock_manager, lock_key)
    launcher = nil
    presence = Integrations::Medelement::SyncJobPresence.new
    return unless recoverable?(candidate, presence)

    hook = candidate.hook
    return fail_unavailable!(candidate, presence, lock_manager, lock_key) unless hook&.enabled? && hook.app_id == 'medelement'

    phases = claim_recovery(candidate, hook, presence, lock_manager, lock_key)
    if phases.present?
      launcher = Integrations::Medelement::ScheduledSyncLauncher.new(
        hook: hook,
        phases: phases,
        preserve_run_on_enqueue_error: true
      )
      launcher.perform
    end
  rescue ActiveJob::EnqueueError
    preserve_failed_enqueue_for_retry!(launcher&.run)
    raise
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def preserve_failed_enqueue_for_retry!(run)
    return unless run&.status.in?(%w[queued retrying])

    # Keep the continuation discoverable by the no-argument recovery retry.
    # rubocop:disable Rails/SkipsModelValidations
    run.update_column(:updated_at, STALE_AFTER.ago - 1.second)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def claim_recovery(candidate, hook, presence, lock_manager, lock_key)
    Integrations::Medelement::HookRuntimeLock.with_hook(account_id: hook.account_id, hook_id: hook.id) do
      run = Integrations::Medelement::SyncRun.lock.find_by(id: candidate.id, hook_id: hook.id)
      next unless recoverable?(run, presence)
      next unless lock_manager.renew(lock_key, Integrations::Medelement::SyncJob::LOCK_TIMEOUT)

      pending = Array(run.summary[Integrations::Medelement::ScheduledSyncLauncher::PENDING_PHASES_KEY])
      phases = ordered_union(run.remaining_phases, pending)
      run.update!(summary: run.summary.except(Integrations::Medelement::ScheduledSyncLauncher::PENDING_PHASES_KEY))
      run.fail!(StaleRunError.new('Medelement sync run heartbeat expired'))
      phases
    end
  end

  def recoverable?(run, presence)
    return false unless run&.status.in?(%w[queued running retrying])

    threshold = presence.owner_known?(run) ? ORPHANED_AFTER : STALE_AFTER
    return false unless run.recovery_activity_at < threshold.ago
    return false if presence.owner_alive?(run)

    !presence.present?(run)
  end

  def fail_unavailable!(run, presence, lock_manager, lock_key)
    run.with_lock do
      run.reload
      next unless recoverable?(run, presence)
      next unless lock_manager.renew(lock_key, Integrations::Medelement::SyncJob::LOCK_TIMEOUT)

      run.fail!(StaleRunError.new('Medelement sync hook is unavailable'))
    end
  end

  def ordered_union(first, second)
    requested = Array(first) | Array(second)
    Integrations::Medelement::SyncRun::PHASES.select { |phase| phase.in?(requested) }
  end
end
