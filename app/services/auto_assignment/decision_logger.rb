# frozen_string_literal: true

class AutoAssignment::DecisionLogger
  pattr_initialize [:inbox!, :policy]

  def assigned(conversation:, assigned_user:, reasons: [], candidate_summaries: [], metadata: {})
    log(
      conversation: conversation,
      outcome: :assigned,
      assigned_user: assigned_user,
      reasons: reasons,
      candidate_summaries: candidate_summaries,
      metadata: metadata
    )
  end

  def skipped(conversation:, reasons:, candidate_summaries: [], metadata: {})
    log(
      conversation: conversation,
      outcome: :skipped,
      reasons: reasons,
      candidate_summaries: candidate_summaries,
      metadata: metadata
    )
  end

  def failed(conversation:, reasons:, candidate_summaries: [], metadata: {})
    log(
      conversation: conversation,
      outcome: :failed,
      reasons: reasons,
      candidate_summaries: candidate_summaries,
      metadata: metadata
    )
  end

  private

  def log(attributes)
    conversation = attributes.fetch(:conversation)

    AssignmentDecisionLog.create!(
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      conversation_id: conversation.id,
      assignment_policy: policy,
      assigned_user: attributes[:assigned_user],
      outcome: attributes.fetch(:outcome),
      reasons: Array(attributes[:reasons]),
      candidate_summaries: Array(attributes[:candidate_summaries]),
      decision_metadata: attributes[:metadata] || {}
    )
  rescue StandardError => e
    Rails.logger.warn("Assignment decision log failed for conversation #{conversation.id}: #{e.class} #{e.message}")
  end
end
