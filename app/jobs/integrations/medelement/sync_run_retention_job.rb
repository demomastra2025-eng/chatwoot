class Integrations::Medelement::SyncRunRetentionJob < ApplicationJob
  queue_as :scheduled_jobs

  RETENTION_PERIOD = 90.days
  BATCH_SIZE = 1000

  def perform
    deleted_count = deletable_runs.in_batches(of: BATCH_SIZE).delete_all
    Rails.logger.info("[MEDELEMENT::SYNC_RUN_RETENTION] deleted_count=#{deleted_count}")
  end

  private

  def deletable_runs
    Integrations::Medelement::SyncRun
      .where(status: Integrations::Medelement::SyncRun::TERMINAL_STATUSES)
      .where(completed_at: ...RETENTION_PERIOD.ago)
      .where.not(id: latest_run_per_hook)
      .where.not(id: actionable_conflict_first_runs)
      .where.not(id: actionable_conflict_last_runs)
  end

  def latest_run_per_hook
    Integrations::Medelement::SyncRun
      .where.not(hook_id: nil)
      .select('DISTINCT ON (hook_id) id')
      .order(:hook_id, created_at: :desc)
  end

  def actionable_conflict_first_runs
    actionable_conflicts.where.not(first_sync_run_id: nil).select(:first_sync_run_id)
  end

  def actionable_conflict_last_runs
    actionable_conflicts.where.not(last_sync_run_id: nil).select(:last_sync_run_id)
  end

  def actionable_conflicts
    Integrations::Medelement::SyncConflict.where(status: %w[open ignored])
  end
end
