class Integrations::Medelement::StaleSyncRunRecoveryJob < ApplicationJob
  queue_as :scheduled_jobs

  STALE_AFTER = 45.minutes
  StaleRunError = Class.new(StandardError)

  retry_on ActiveJob::EnqueueError, wait: 30.seconds, attempts: 24

  def perform
    Integrations::Medelement::SyncRun.active.where(updated_at: ...STALE_AFTER.ago).find_each do |candidate|
      recover(candidate)
    end
  end

  private

  def recover(candidate)
    launcher = nil
    hook = candidate.hook
    return fail_unavailable!(candidate) unless hook&.enabled? && hook.app_id == 'medelement'

    phases = claim_recovery(candidate, hook)
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

  def claim_recovery(candidate, hook)
    Integrations::Medelement::HookRuntimeLock.with_hook(account_id: hook.account_id, hook_id: hook.id) do
      run = Integrations::Medelement::SyncRun.lock.find_by(id: candidate.id, hook_id: hook.id)
      next unless stale_active_run?(run)

      pending = Array(run.summary[Integrations::Medelement::ScheduledSyncLauncher::PENDING_PHASES_KEY])
      phases = ordered_union(run.remaining_phases, pending)
      run.update!(summary: run.summary.except(Integrations::Medelement::ScheduledSyncLauncher::PENDING_PHASES_KEY))
      run.fail!(StaleRunError.new('Medelement sync run heartbeat expired'))
      phases
    end
  end

  def stale_active_run?(run)
    run&.status.in?(%w[queued running retrying]) && run.updated_at < STALE_AFTER.ago
  end

  def fail_unavailable!(run)
    run.with_lock do
      run.reload
      next unless stale_active_run?(run)

      run.fail!(StaleRunError.new('Medelement sync hook is unavailable'))
    end
  end

  def ordered_union(first, second)
    requested = Array(first) | Array(second)
    Integrations::Medelement::SyncRun::PHASES.select { |phase| phase.in?(requested) }
  end
end
