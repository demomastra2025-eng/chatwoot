class AutomationRules::PublishEventJob < ApplicationJob
  ACTIVATION_ENV = 'AUTOMATION_DURABLE_EVENT_PUBLICATION_ENABLED'.freeze

  queue_as :default
  self.enqueue_after_transaction_commit = false

  retry_on StandardError, attempts: 1 do |job, error|
    Rails.logger.error("Automation event publication #{job.arguments.first} failed: #{error.class}: #{error.message}")
  end

  def self.perform_later!(*)
    job = new(*)
    job.enqueue
    return job if job.successfully_enqueued?

    raise job.enqueue_error || ActiveJob::EnqueueError.new('Automation event publication was not enqueued')
  end

  def self.enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(ACTIVATION_ENV, false))
  end

  def perform(event_id = nil, reservation_token = nil)
    AutomationRules::Events::Publisher.new(event_id, reservation_token: reservation_token).perform
  end
end
