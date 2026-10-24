class Captain::TasksPolicy < ApplicationPolicy
  def rewrite?
    true
  end

  def summarize?
    true
  end

  def reply_suggestion?
    true
  end

  # Conversation-level access is checked by the controller (ConversationPolicy#show?).
  def reply_suggestion_status?
    true
  end

  def cancel_reply_suggestion?
    true
  end

  def label_suggestion?
    true
  end

  def follow_up?
    true
  end

  def approve_action?
    true
  end

  def reject_action?
    true
  end
end
