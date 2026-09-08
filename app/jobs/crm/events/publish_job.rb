class Crm::Events::PublishJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 10
  discard_on ActiveRecord::RecordNotFound

  def self.perform_later!(*)
    job = perform_later(*)
    return job if job.successfully_enqueued?

    raise job.enqueue_error || ActiveJob::EnqueueError.new('CRM event publication was not enqueued')
  end

  def perform(event_id)
    Crm::Event.find(event_id).publish!
  end
end
