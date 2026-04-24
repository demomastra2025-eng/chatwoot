# Evaluates whether a conversation is complete and can be auto-resolved.
# Used by InboxPendingConversationsResolutionJob to determine if inactive
# conversations should be resolved or handed off to human agents.
#
# NOTE: This service intentionally does NOT count toward Captain usage limits.
# Enterprise::Captain::ConversationCompletionService marks results as non-billable even when
# they include a customer-facing generated message for auto-resolve/handoff flows.
class Captain::ConversationCompletionService < Captain::BaseTaskService
  pattr_initialize [:account!, :conversation_display_id!]

  def perform
    evaluator.perform
  end

  private

  def evaluator
    Captain::ConversationCompletionEvaluator.new(
      account: account,
      conversation_display_id: conversation_display_id,
      messages: conversation_messages(start_from: 0)
    )
  end
end

Captain::ConversationCompletionService.prepend_mod_with('Captain::ConversationCompletionService')
