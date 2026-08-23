class Whatsapp::PendingMessageMutationSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 250

  def perform
    enqueue_due_reconciliations
    scrub_expired_payloads
  end

  private

  def enqueue_due_reconciliations
    Whatsapp::PendingMessageMutation.due_for_reconciliation.order(:id).limit(BATCH_SIZE).each do |pending_mutation|
      Whatsapp::PendingMessageMutationReconciliationJob.enqueue_due(pending_mutation)
    rescue StandardError => e
      Rails.logger.error(
        "[WHATSAPP] Pending mutation reconciliation enqueue failed id=#{pending_mutation.id} error=#{e.class}"
      )
    end
  end

  def scrub_expired_payloads
    Whatsapp::PendingMessageMutation.due_for_payload_scrub.order(:id).limit(BATCH_SIZE).each do |pending_mutation|
      pending_mutation.scrub_exhausted_payload!
    rescue StandardError => e
      Rails.logger.error(
        "[WHATSAPP] Pending mutation payload scrub failed id=#{pending_mutation.id} error=#{e.class}"
      )
    end
  end
end
