class Crm::Events::ReplayUnpublishedJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100

  def perform
    Crm::Event.ready_for_publication.order(:publication_next_attempt_at, :id).limit(BATCH_SIZE).pluck(:id).each do |event_id|
      Crm::Event.find(event_id).enqueue_publication!
    rescue ActiveRecord::RecordNotFound
      next
    rescue ActiveJob::EnqueueError => e
      Rails.logger.error("CRM publication #{event_id} enqueue failed: #{e.message}")
    end
  end
end
