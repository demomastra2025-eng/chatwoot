class Whatsapp::PendingMessageMutationReconciliationJob < ApplicationJob
  queue_as :low

  def self.enqueue_due(pending_mutation)
    claim_token = pending_mutation.claim_reconciliation!
    return false if claim_token.blank?

    perform_later(pending_mutation.id, claim_token: claim_token)
    true
  rescue StandardError
    pending_mutation.release_reconciliation_claim!(claim_token) if claim_token.present?
    raise
  end

  def perform(pending_mutation_id, claim_token: nil, force: false)
    pending_mutation = Whatsapp::PendingMessageMutation.find_by(id: pending_mutation_id)
    if force
      return unless pending_mutation&.reactivate_exhausted_payload!
    else
      return unless replayable?(pending_mutation, claim_token)
    end

    reconcile(pending_mutation, claim_token)
  rescue ActiveRecord::RecordNotFound
    nil
  end

  private

  def replayable?(pending_mutation, claim_token)
    return false if pending_mutation.blank?
    return pending_mutation.pending? if claim_token.blank?

    pending_mutation.reconciliation_claim_owned?(claim_token)
  end

  def reconcile(pending_mutation, claim_token)
    result = Whatsapp::PendingMessageMutationService
             .new(inbox: pending_mutation.inbox, message: nil)
             .replay(pending_mutation)
    return unless result == :pending

    pending_mutation.reload
    expire_or_reschedule(pending_mutation, claim_token)
  end

  def expire_or_reschedule(pending_mutation, claim_token)
    if pending_mutation.expired?
      pending_mutation.mark_exhausted!
      log_exhausted(pending_mutation)
    else
      pending_mutation.schedule_reconciliation_at!(pending_mutation.expires_at, claim_token: claim_token)
    end
  end

  def log_exhausted(pending_mutation)
    Rails.logger.warn(
      "[WHATSAPP] Pending mutation exhausted id=#{pending_mutation.id} " \
      "account=#{pending_mutation.account_id} inbox=#{pending_mutation.inbox_id} type=#{pending_mutation.mutation_type}"
    )
  end
end
