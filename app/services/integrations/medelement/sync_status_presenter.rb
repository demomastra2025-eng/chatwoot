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
      phase_statuses: phase_statuses,
      schedules: Integrations::Medelement::CronScheduleService.new(hook: hook).schedule_payload,
      delta: delta_status,
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
    sync_runs.recent.first
  end

  def delta_status
    configuration = Integrations::Medelement::Configuration.new(hook: hook)
    return { enabled: false } unless delta_enabled?(configuration)

    cursor = Integrations::Medelement::SyncCursor.find_by(hook_id: hook.id, name: 'receptions_delta')
    cursor_status(cursor, configuration).merge(delta_miss_counts)
  end

  def delta_enabled?(configuration)
    configuration.incremental_receptions_enabled? && configuration.sync_receptions? && hook.enabled?
  end

  def cursor_status(cursor, configuration)
    {
      enabled: true,
      last_poll_at: cursor&.last_poll_at&.iso8601,
      last_success_at: cursor&.last_success_at&.iso8601,
      cursor_age_seconds: cursor&.value && (Time.current - cursor.value).to_i,
      current_interval_seconds: cursor&.current_interval_seconds || configuration.incremental_receptions_interval_seconds
    }
  end

  def delta_miss_counts
    misses = Integrations::Medelement::DeltaMiss.where(hook_id: hook.id, detected_at: 24.hours.ago..)
    {
      misses_24h: misses.count,
      unexplained_misses_24h: misses.where(classification: 'unexplained').count
    }
  end

  def phase_statuses
    Integrations::Medelement::SyncRun::PHASES.index_with do |phase|
      run = sync_runs.where('phase_results ? :phase', phase: phase).recent.first
      next unless run

      result = run.phase_results[phase]
      {
        run_id: run.id,
        trigger: run.trigger,
        status: result['status'],
        result: result,
        last_synced_at: result['completed_at'] || run.completed_at&.iso8601 || run.updated_at.iso8601
      }
    end
  end

  def sync_runs
    Integrations::Medelement::SyncRun.where(account_id: hook.account_id, hook_id: hook.id)
  end
end
