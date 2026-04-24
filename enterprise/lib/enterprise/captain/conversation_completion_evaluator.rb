# Overrides quota/usage accounting from Enterprise::Captain::BaseTaskService
# for the internal conversation-completion evaluator. Auto-resolve evaluation
# must run regardless of customer quota and must not count as a billable response,
# even when it returns a generated customer-facing handoff/resolution message.
module Enterprise::Captain::ConversationCompletionEvaluator
  private

  def responses_available?
    true
  end

  def successful_result?(_result)
    false
  end
end
