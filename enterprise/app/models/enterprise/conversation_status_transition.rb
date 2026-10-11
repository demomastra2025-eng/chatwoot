# frozen_string_literal: true

module Enterprise::ConversationStatusTransition
  extend ActiveSupport::Concern

  prepended do
    before_create :prepare_captain_outcome_classification
    after_create_commit :enqueue_captain_outcome_classification
  end

  private

  def prepare_captain_outcome_classification
    return unless Captain::OutcomeClassificationService.eligible?(self)

    snapshot = Captain::OutcomeClassificationService.snapshot(self)
    self.metadata = metadata.except('outcome_reason_id').merge(
      'assistant_id' => actor_id, 'outcome_reason_type' => snapshot['type'],
      'outcome_classification' => snapshot
    )
  end

  def enqueue_captain_outcome_classification
    return unless metadata.dig('outcome_classification', 'state') == 'pending'

    Captain::OutcomeClassificationJob.perform_later(id)
  rescue StandardError => e
    # The transition has committed. A classifier outage must never undo handoff;
    # the recovery job picks up the durable pending marker.
    Rails.logger.warn("[CAPTAIN][Outcome] Enqueue failed transition_id=#{id} error=#{e.class}")
  end
end
