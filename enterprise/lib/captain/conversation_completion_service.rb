# Evaluates whether a conversation is complete and can be auto-resolved.
# Used by InboxPendingConversationsResolutionJob to determine if inactive
# conversations should be resolved or handed off to human agents.
#
# NOTE: This service intentionally does NOT count toward Captain usage limits.
# The response excludes the :message key that Enterprise::Captain::BaseTaskService
# checks for usage tracking. This is an internal operational evaluation,
# not a customer-facing value-add, so we don't charge for it.
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
