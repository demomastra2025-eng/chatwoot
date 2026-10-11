# frozen_string_literal: true

class Internal::RecoverCaptainOutcomeClassificationsJob < ApplicationJob
  queue_as :low

  def perform
    return unless defined?(Captain::OutcomeClassificationJob)

    # Only this feature's durable markers; never classify historical transitions
    # or replay a customer-facing action. Bound each recovery pass.
    ConversationStatusTransition.where("metadata->'outcome_classification'->>'state' IN (?)", %w[pending processing])
                                .where('updated_at < ?', 10.minutes.ago)
                                .order(:updated_at).limit(100).pluck(:id).each do |id|
      Captain::OutcomeClassificationJob.perform_later(id)
    end
  end
end
