class ConversationPolicy < ApplicationPolicy
  def index?
    true
  end

  def destroy?
    administrator?
  end

  def show?
    administrator? || agent_bot? || agent_can_view_conversation?
  end

  private

  def agent_can_view_conversation?
    return false unless account_user.present? && record.account_id == account&.id
    return true unless record.inbox&.channel_type == 'Channel::Voice'
    return user_context[:voice_member_user_ids].include?(user.id) if user_context.key?(:voice_member_user_ids)

    user.inboxes.where(account_id: account.id, channel_type: 'Channel::Voice').exists?(id: record.inbox_id)
  end

  def administrator?
    account_user&.administrator?
  end

  def agent_bot?
    user.is_a?(AgentBot)
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
