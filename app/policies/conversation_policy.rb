class ConversationPolicy < ApplicationPolicy
  def index?
    true
  end

  def destroy?
    administrator?
  end

  def show?
    administrator? || agent_can_view_conversation?
  end

  private

  def agent_can_view_conversation?
    account_user.present? && record.account_id == account&.id
  end

  def administrator?
    account_user&.administrator?
  end


  def assigned_to_user?
    record.assignee_id == user.id
  end

  def participant?
    return user_context[:participant_user_ids].include?(user.id) if user_context.key?(:participant_user_ids)

    record.conversation_participants.exists?(user_id: user.id)
  end
end

ConversationPolicy.prepend_mod_with('ConversationPolicy')
