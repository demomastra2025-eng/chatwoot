class Crm::Events::ReplayUnpublishedJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100

  def perform
    Crm::Event.unpublished.order(:id).limit(BATCH_SIZE).pluck(:id).each do |event_id|
      Crm::Events::PublishJob.perform_later!(event_id)
    end
  end
end
