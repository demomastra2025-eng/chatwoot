class Crm::Events::PublishJob < ApplicationJob
  queue_as :default

  # The durable outbox owns retries; a second queue retry loop would bypass its
  # backoff and duplicate pending jobs. A failed DB write leaves the lease to expire.
  retry_on StandardError, attempts: 1 do |job, error|
    Rails.logger.error("CRM publication #{job.arguments.first} failed: #{error.class}: #{error.message}")
  end
  discard_on ActiveRecord::RecordNotFound

  def self.perform_later!(*)
    job = new(*)
    job.enqueue
    return job if job.successfully_enqueued?

    raise job.enqueue_error || ActiveJob::EnqueueError.new('CRM event publication was not enqueued')
  end

  def perform(event_id)
    Crm::Event.find(event_id).publish!
  end
end
