# frozen_string_literal: true

class Captain::OutcomeClassificationJob < ApplicationJob
  queue_as :low

  def perform(transition_id)
    transition = ConversationStatusTransition.find_by(id: transition_id)
    return unless transition

    Captain::OutcomeClassificationService.new(transition).perform
  end
end
