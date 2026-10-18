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
    inbox_access? || team_access?
  end

  def administrator?
    account_user&.administrator?
  end

  def inbox_access?
    return preloaded_member_access?(record.inbox) if preloaded_members?(record, :inbox)

    user.inboxes.where(account_id: account&.id).exists?(id: record.inbox_id)
  end

  def team_access?
    return false if record.team_id.blank?
    return preloaded_member_access?(record.team) if preloaded_members?(record, :team)

    user.teams.where(account_id: account&.id).exists?(id: record.team_id)
  end

  def preloaded_members?(owner, association_name)
    owner.association(association_name).loaded? &&
      owner.public_send(association_name)&.association(:members)&.loaded?
  end

  def preloaded_member_access?(group_record)
    group_record.account_id == account&.id && group_record.members.any? { |member| member.id == user.id }
  end

  def assigned_to_user?
    record.assignee_id == user.id
  end

  def participant?
    record.conversation_participants.exists?(user_id: user.id)
  end
end

ConversationPolicy.prepend_mod_with('ConversationPolicy')
