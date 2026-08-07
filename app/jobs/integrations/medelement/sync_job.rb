class Integrations::Medelement::SyncJob < MutexApplicationJob
  queue_as :medium
  LOCK_TIMEOUT = 10.minutes

  retry_on LockAcquisitionError, wait: 30.seconds, attempts: 6
  retry_on Integrations::Medelement::Client::ApiError, wait: 1.minute, attempts: 3
  retry_on Integrations::Medelement::ReceptionsSyncService::IncompleteSnapshotError, wait: 5.minutes, attempts: 3
  retry_on Integrations::Medelement::ServicesSyncService::IncompleteSnapshotError, wait: 5.minutes, attempts: 3
  retry_on Integrations::Medelement::SpecialistsSnapshotService::IncompleteSnapshotError, wait: 5.minutes, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(hook_id, sync_run_id = nil)
    hook = Integrations::Hook.find(hook_id)
    sync_run = find_or_create_sync_run(hook, sync_run_id)
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

  def find_or_create_sync_run(hook, sync_run_id)
    if sync_run_id.present?
      return Integrations::Medelement::SyncRun.find_by!(
        id: sync_run_id,
        account_id: hook.account_id,
        hook_id: hook.id
      )
    end

    create_scheduled_sync_run(hook)
  end

  def create_scheduled_sync_run(hook)
    Integrations::Medelement::HookRuntimeLock.with_hook(account_id: hook.account_id, hook_id: hook.id) do |locked_hook|
      next if Integrations::Medelement::SyncRun.active.exists?(hook_id: locked_hook.id)

      Integrations::Medelement::SyncRun.create!(account: locked_hook.account, hook: locked_hook, trigger: 'scheduled')
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def retryable_error?(error)
    error.is_a?(LockAcquisitionError) ||
      error.is_a?(Integrations::Medelement::Client::ApiError) ||
      error.is_a?(Integrations::Medelement::ReceptionsSyncService::IncompleteSnapshotError) ||
      error.is_a?(Integrations::Medelement::ServicesSyncService::IncompleteSnapshotError) ||
      error.is_a?(Integrations::Medelement::SpecialistsSnapshotService::IncompleteSnapshotError)
  end

  def retry_attempts_for(error)
    error.is_a?(LockAcquisitionError) ? 6 : 3
  end

  def lock_key(account_id)
    format(::Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account_id)
  end
end
