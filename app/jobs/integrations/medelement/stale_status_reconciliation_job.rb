# Without a hook id (the nightly cron entry in config/schedule.yml) it queues one run per enabled MedElement hook; with a
# hook id it runs the stale status reconciliation for that hook. The runs read MedElement slowly, one reception per
# throttle interval, so they go to the low queue and leave the sync queues to the live sync.
#
#   Integrations::Medelement::StaleStatusReconciliationJob.perform_later(hook.id, days: nil, dry_run: true)
#
# days: nil reads the whole history. max_per_run: nil removes the cap of one run.
class Integrations::Medelement::StaleStatusReconciliationJob < ApplicationJob
  queue_as :low

  # The runs of different clinics do not compete for the same provider limit, but they do for workers.
  STAGGER = 20.seconds

  discard_on ActiveRecord::RecordNotFound

  def perform(hook_id = nil, days: Integrations::Medelement::StaleStatusReconciler::DEFAULT_DAYS, dry_run: false,
              max_per_run: Integrations::Medelement::StaleStatusReconciler::DEFAULT_MAX_PER_RUN)
    return enqueue_runs(days, dry_run, max_per_run) if hook_id.nil?

    hook = Integrations::Hook.find_by!(id: hook_id, app_id: 'medelement')
    Integrations::Medelement::StaleStatusReconciler.new(
      hook: hook, days: days, dry_run: dry_run, max_per_run: max_per_run
    ).perform.to_h
  end

  private

  def enqueue_runs(days, dry_run, max_per_run)
    Integrations::Hook.where(app_id: 'medelement', status: 'enabled').order(:id).pluck(:id).each_with_index do |id, index|
      self.class.set(wait: index * STAGGER).perform_later(id, days: days, dry_run: dry_run, max_per_run: max_per_run)
    end
  end
end
