class Integrations::Medelement::ScheduledSyncJob < ApplicationJob
  queue_as :scheduled_jobs

  retry_on ActiveJob::EnqueueError, wait: 30.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(hook_id, phases)
    hook = Integrations::Hook.find_by!(id: hook_id, app_id: 'medelement')
    return unless hook.enabled?

    Integrations::Medelement::ScheduledSyncLauncher.new(hook: hook, phases: phases).perform
  end
end
