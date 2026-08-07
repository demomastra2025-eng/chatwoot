class Integrations::Medelement::SyncStatusPresenter
  CONFLICT_LIMIT = 100

  def initialize(hook:)
    @hook = hook
  end

  def payload(run: latest_run)
    conflicts = conflict_scope.actionable.limit(CONFLICT_LIMIT)

    {
      run: run&.api_payload,
      conflicts: conflicts.map(&:api_payload),
      conflict_counts: {
        open: conflict_scope.open.count,
        ignored: conflict_scope.ignored.count
      },
      truncated: conflicts.size == CONFLICT_LIMIT
    }
  end

  private

  attr_reader :hook

  def conflict_scope
    Integrations::Medelement::SyncConflict.where(account_id: hook.account_id, hook_id: hook.id)
  end

  def latest_run
    Integrations::Medelement::SyncRun.where(account_id: hook.account_id, hook_id: hook.id).recent.first
  end
end
