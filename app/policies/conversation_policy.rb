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
    return false unless account_user.present? && record.account_id == account&.id
    return true unless account.feature_enabled?('communication_threads')

    communication_thread = record.communication_thread
    return false if communication_thread.blank?

    CommunicationThreadPolicy.new(user_context, communication_thread).show?
  end

  def administrator?
    account_user&.administrator?
  end

  def assigned_to_user?
    record.assignee_id == user.id
  end

  def participant?
    return user_context[:participant_user_ids].include?(user.id) if user_context.key?(:participant_user_ids)
    return record.conversation_participants.exists?(user_id: user.id) unless account.feature_enabled?('communication_threads')

    record.communication_thread&.communication_thread_participants&.exists?(user_id: user.id) || false
  end
end

ConversationPolicy.prepend_mod_with('ConversationPolicy')
