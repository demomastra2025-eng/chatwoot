class Integrations::Medelement::SyncRunRetentionJob < ApplicationJob
  queue_as :scheduled_jobs

  SUCCEEDED_RETENTION_PERIOD = 7.days
  FAILED_RETENTION_PERIOD = 30.days
  RETENTION_PERIOD = FAILED_RETENTION_PERIOD
  BATCH_SIZE = 1000

  def perform
    deleted_count = deletable_runs.in_batches(of: BATCH_SIZE).delete_all
    Rails.logger.info("[MEDELEMENT::SYNC_RUN_RETENTION] deleted_count=#{deleted_count}")
  end

  private

  def deletable_runs
    base_scope = Integrations::Medelement::SyncRun
      .where(status: Integrations::Medelement::SyncRun::TERMINAL_STATUSES)
      .where.not(id: latest_run_per_hook)
      .where.not(id: actionable_conflict_first_runs)
      .where.not(id: actionable_conflict_last_runs)

    base_scope.where(status: 'succeeded', completed_at: ...SUCCEEDED_RETENTION_PERIOD.ago)
              .or(base_scope.where.not(status: 'succeeded').where(completed_at: ...FAILED_RETENTION_PERIOD.ago))
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
