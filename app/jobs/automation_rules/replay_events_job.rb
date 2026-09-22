class AutomationRules::ReplayEventsJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    return unless AutomationRules::PublishEventJob.enabled?

    AutomationRules::Events::WakeupService.enqueue_batch!
  end
end
