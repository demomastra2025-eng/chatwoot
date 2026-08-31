class Integrations::Medelement::ReceptionsWindowSelector
  FULL_AUDIT_INTERVAL = 24.hours

  def initialize(hook:, sync_run:)
    @hook = hook
    @sync_run = sync_run
  end

  def call
    return :full unless sync_run&.trigger == 'scheduled'

    recent_full_audit? ? :realtime : :full
  end

  private

  attr_reader :hook, :sync_run

  def recent_full_audit?
    Integrations::Medelement::SyncRun
      .where(account_id: hook.account_id, hook_id: hook.id)
      .where(status: Integrations::Medelement::SyncRun::TERMINAL_STATUSES)
      .where(completed_at: FULL_AUDIT_INTERVAL.ago..)
      .where("phase_results -> 'receptions' ->> 'status' = ?", 'succeeded')
      .exists?(["phase_results -> 'receptions' ->> 'window_mode' = ?", 'full'])
  end
end
