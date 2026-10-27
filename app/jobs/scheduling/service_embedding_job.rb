# frozen_string_literal: true

# Gives the services of one account whose text or model changed a new vector (see Scheduling::ServiceIndex). A burst of saves, such as
# a MedElement catalog sync that touches every service, queues one delayed job per account; the job reads the stale services when it
# runs, embeds them in batches (one request per 64 services) and skips every service whose checksum and model are current.
class Scheduling::ServiceEmbeddingJob < ApplicationJob
  queue_as :low

  # The wait that lets a burst of saves join one job.
  DEBOUNCE = 30.seconds

  class << self
    # Queues the refresh of an account unless one is already queued. Returns true when a job was queued.
    def enqueue(account_id, wait: DEBOUNCE)
      key = queued_key(account_id)
      return false if Redis::Alfred.set(key, 1, nx: true, ex: (wait.to_i + 10.minutes.to_i)).blank?

      set(wait: wait).perform_later(account_id)
      true
    rescue StandardError
      Redis::Alfred.delete(key) if key
      raise
    end

    def queued_key(account_id)
      format(Redis::Alfred::SCHEDULING_SERVICE_EMBEDDING_QUEUED, account_id: account_id)
    end
  end

  def perform(account_id)
    # a save during the run queues a new refresh
    Redis::Alfred.delete(self.class.queued_key(account_id))
    count = Scheduling::ServiceIndex.refresh!(account_id)
    Rails.logger.info("[Scheduling::ServiceEmbeddingJob] account #{account_id}: #{count} services embedded") if count.positive?
  rescue Captain::Llm::EmbeddingService::EmbeddingsUnavailableError => e
    Rails.logger.warn("[Scheduling::ServiceEmbeddingJob] account #{account_id}: #{e.message}")
  end
end
