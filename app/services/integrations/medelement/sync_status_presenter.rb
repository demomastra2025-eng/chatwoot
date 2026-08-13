class Integrations::Medelement::SyncStatusPresenter
  CONFLICT_LIMIT = 25

  def initialize(hook:, conflict_page: 1, filters: {})
    @hook = hook
    @conflict_page = [conflict_page.to_i, 1].max
    @filters = filters.to_h.symbolize_keys
  end

  def payload(run: latest_run)
    listed_scope = Integrations::Medelement::SyncConflictFilter.new(hook: hook, filters: filters).apply

    {
      run: run&.api_payload,
      conflicts: presented_conflicts(listed_scope),
      conflict_counts: conflict_counts,
      conflict_pagination: conflict_pagination(listed_scope.count)
    }
  end

  private

  attr_reader :hook, :conflict_page, :filters

  def conflict_scope
    Integrations::Medelement::SyncConflict.where(account_id: hook.account_id, hook_id: hook.id)
  end

  def presented_conflicts(scope)
    conflicts = scope.offset((conflict_page - 1) * CONFLICT_LIMIT).limit(CONFLICT_LIMIT).to_a
    entity_preloader = Integrations::Medelement::ConflictEntityPreloader.new(account: hook.account, conflicts: conflicts)
    conflicts.map do |conflict|
      Integrations::Medelement::ConflictPresenter.new(conflict: conflict, entity_preloader: entity_preloader).payload
    end
  end

  def conflict_counts
    {
      open: conflict_scope.open.count,
      ignored: conflict_scope.ignored.count,
      resolved: conflict_scope.resolved.count
    }
  end

  def conflict_pagination(total)
    {
      page: conflict_page,
      per_page: CONFLICT_LIMIT,
      total: total,
      total_pages: [(total.to_f / CONFLICT_LIMIT).ceil, 1].max
    }
  end

  def latest_run
    Integrations::Medelement::SyncRun.where(account_id: hook.account_id, hook_id: hook.id).recent.first
  end
end
