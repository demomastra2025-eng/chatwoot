class Integrations::Medelement::ScheduledSyncLauncher
  PENDING_PHASES_KEY = 'pending_phases'.freeze

  attr_reader :run

  def initialize(hook:, phases:, preserve_run_on_enqueue_error: false)
    @hook = hook
    @phases = normalize_phases(phases)
    @preserve_run_on_enqueue_error = preserve_run_on_enqueue_error
  end

  def perform
    @run = nil
    enqueued = false

    Integrations::Medelement::HookRuntimeLock.with_hook(account_id: hook.account_id, hook_id: hook.id) do |locked_hook|
      @run, enqueued = launch_or_merge(locked_hook)
    end

    enqueue_sync_job!(run) if enqueued
    [run, enqueued]
  rescue ActiveRecord::RecordNotUnique
    retry
  rescue StandardError => e
    run&.fail!(e) if enqueued && !preserve_run_on_enqueue_error && !run.terminal?
    raise
  end

  def self.enqueue_pending!(hook:, completed_run:)
    pending_phases = completed_run.with_lock do
      completed_run.reload
      Array(completed_run.summary[PENDING_PHASES_KEY]).map(&:to_s).uniq
    end
    return if pending_phases.empty?

    new(hook: hook, phases: pending_phases).perform
    completed_run.with_lock do
      completed_run.reload
      completed_run.update!(summary: completed_run.summary.except(PENDING_PHASES_KEY))
    end
  end

  private

  attr_reader :hook, :phases, :preserve_run_on_enqueue_error

  def enqueue_sync_job!(run)
    job = Integrations::Medelement::SyncJob.perform_later(hook.id, run.id)
    return if job&.successfully_enqueued?

    raise ActiveJob::EnqueueError, 'Failed to enqueue scheduled Medelement sync job'
  end

  def launch_or_merge(locked_hook)
    active_run = Integrations::Medelement::SyncRun.active.find_by(hook_id: locked_hook.id)
    return [active_run, false] if active_run && merge_into_active_run!(active_run)

    run = Integrations::Medelement::SyncRun.create!(
      account: locked_hook.account,
      hook: locked_hook,
      trigger: 'scheduled',
      requested_phases: phases
    )
    [run, true]
  end

  def merge_into_active_run!(run)
    run.with_lock do
      run.reload
      next false if run.terminal?

      if run.queued? || run.retrying?
        run.update!(requested_phases: ordered_union(run.phases, phases))
      else
        pending = Array(run.summary[PENDING_PHASES_KEY])
        run.update!(summary: run.summary.merge(PENDING_PHASES_KEY => ordered_union(pending, phases)))
      end
      true
    end
  end

  def normalize_phases(values)
    requested = Array(values).map(&:to_s).uniq
    unsupported = requested - Integrations::Medelement::SyncRun::PHASES
    raise ArgumentError, "Unsupported Medelement sync phases: #{unsupported.join(', ')}" if unsupported.present?

    requested.presence || Integrations::Medelement::SyncRun::PHASES
  end

  def ordered_union(first, second)
    Integrations::Medelement::SyncRun::PHASES.select { |phase| phase.in?(Array(first) | Array(second)) }
  end
end
