class Integrations::Medelement::SyncRunLauncher
  def initialize(hook:, requested_by: nil, phases: nil)
    @hook = hook
    @requested_by = requested_by
    @phases = normalize_phases(phases)
  end

  def perform
    run, enqueued = create_or_find_run
    Integrations::Medelement::SyncJob.perform_later(hook.id, run.id) if enqueued
    [run, enqueued]
  rescue ActiveRecord::RecordNotUnique
    retry
  rescue StandardError => e
    run&.fail!(e)
    raise
  end

  private

  attr_reader :hook, :phases, :requested_by

  def create_or_find_run
    Integrations::Medelement::HookRuntimeLock.with_hook(account_id: hook.account_id, hook_id: hook.id) do |locked_hook|
      existing_run = active_run
      next [existing_run, false] if existing_run

      run = Integrations::Medelement::SyncRun.create!(
        account: locked_hook.account,
        hook: locked_hook,
        requested_by: requested_by,
        trigger: phases.present? ? 'retry' : 'manual',
        requested_phases: phases
      )
      [run, true]
    end
  end

  def active_run
    Integrations::Medelement::SyncRun.active.where(hook_id: hook.id).recent.first
  end

  def normalize_phases(values)
    Array(values).map(&:to_s).uniq.tap do |requested|
      unsupported = requested - Integrations::Medelement::SyncRun::PHASES
      raise ArgumentError, "Unsupported Medelement sync phases: #{unsupported.join(', ')}" if unsupported.present?
    end
  end
end
