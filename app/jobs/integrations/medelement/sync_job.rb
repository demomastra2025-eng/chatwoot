class Integrations::Medelement::SyncJob < MutexApplicationJob
  queue_as :medium
  LOCK_TIMEOUT = 2.hours
  ScheduledSyncBusyError = Class.new(StandardError)

  retry_on ScheduledSyncBusyError, wait: 5.minutes, attempts: 24
  retry_on LockAcquisitionError, wait: 30.seconds, attempts: 6
  retry_on Integrations::Medelement::Client::ApiError, wait: 1.minute, attempts: 3
  retry_on Integrations::Medelement::ReceptionsSyncService::IncompleteSnapshotError, wait: 5.minutes, attempts: 3
  retry_on Integrations::Medelement::ServicesSyncService::IncompleteSnapshotError, wait: 5.minutes, attempts: 3
  retry_on Integrations::Medelement::SpecialistsSnapshotService::IncompleteSnapshotError, wait: 5.minutes, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(hook_id, sync_run_id = nil, scheduled_phases = nil)
    hook = Integrations::Hook.find(hook_id)
    sync_run = find_or_create_sync_run(hook, sync_run_id, scheduled_phases)
    return unless sync_run

    with_lock(lock_key(hook.account_id), LOCK_TIMEOUT) do
      execute_sync(hook, sync_run)
    end
  rescue StandardError => e
    if retryable_error?(e) && executions < retry_attempts_for(e)
      sync_run&.retry!(e)
    else
      sync_run&.fail!(e) unless sync_run&.failed?
    end
    raise
  end

  private

  def execute_sync(hook, sync_run)
    hook.reload
    sync_run.reload
    return if sync_run.terminal?

    sync_run.start!
    Integrations::Medelement::SyncCoordinatorService.new(hook: hook).perform(
      sync_run: sync_run,
      phases: sync_run.remaining_phases
    )
  end

  def find_or_create_sync_run(hook, sync_run_id, scheduled_phases)
    if sync_run_id.present?
      return Integrations::Medelement::SyncRun.find_by!(
        id: sync_run_id,
        account_id: hook.account_id,
        hook_id: hook.id
      )
    end

    create_scheduled_sync_run(hook, scheduled_phases)
  end

  def create_scheduled_sync_run(hook, scheduled_phases = nil)
    normalized_phases = normalized_scheduled_phases(scheduled_phases)
    Integrations::Medelement::HookRuntimeLock.with_hook(account_id: hook.account_id, hook_id: hook.id) do |locked_hook|
      active_run = Integrations::Medelement::SyncRun.active.find_by(hook_id: locked_hook.id)
      return active_run if resumable_scheduled_run?(active_run, normalized_phases)
      next if scheduled_phases_covered_by?(active_run, normalized_phases)
      raise ScheduledSyncBusyError, 'Medelement scheduled phases are waiting for the active sync run' if active_run

      Integrations::Medelement::SyncRun.create!(
        account: locked_hook.account,
        hook: locked_hook,
        trigger: 'scheduled',
        requested_phases: normalized_phases
      )
    end
  rescue ActiveRecord::RecordNotUnique
    raise ScheduledSyncBusyError, 'Medelement scheduled phases collided with another sync run'
  end

  def normalized_scheduled_phases(phases)
    requested = Array(phases).map(&:to_s).uniq
    unsupported = requested - Integrations::Medelement::SyncRun::PHASES
    raise ArgumentError, "Unsupported Medelement sync phases: #{unsupported.join(', ')}" if unsupported.present?

    requested
  end

  def scheduled_phases_covered_by?(active_run, scheduled_phases)
    return false unless active_run

    effective_phases = scheduled_phases.presence || Integrations::Medelement::SyncRun::PHASES
    (effective_phases - active_run.phases).empty?
  end

  def resumable_scheduled_run?(active_run, scheduled_phases)
    active_run&.trigger == 'scheduled' && active_run.retrying? && scheduled_phases_covered_by?(active_run, scheduled_phases)
  end

  def retryable_error?(error)
    error.is_a?(ScheduledSyncBusyError) ||
      error.is_a?(LockAcquisitionError) ||
      error.is_a?(Integrations::Medelement::Client::ApiError) ||
      error.is_a?(Integrations::Medelement::ReceptionsSyncService::IncompleteSnapshotError) ||
      error.is_a?(Integrations::Medelement::ServicesSyncService::IncompleteSnapshotError) ||
      error.is_a?(Integrations::Medelement::SpecialistsSnapshotService::IncompleteSnapshotError)
  end

  def retry_attempts_for(error)
    return 24 if error.is_a?(ScheduledSyncBusyError)
    return 6 if error.is_a?(LockAcquisitionError)

    3
  end

  def lock_key(account_id)
    format(::Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account_id)
  end
end
