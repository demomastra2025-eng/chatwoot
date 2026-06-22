# frozen_string_literal: true

class AutoAssignment::StickyOwnerService
  pattr_initialize [:inbox!, :policy]

  def available_owner_for(conversation, candidate_members)
    owner = owner_for(conversation)
    return nil unless owner

    candidate_user_ids = candidate_members.filter_map { |member| agent_user(member)&.id }
    candidate_user_ids.include?(owner.id) ? owner : nil
  end

  def owner_for(conversation)
    return nil unless sticky_owner_enabled?
    return nil if conversation.contact_id.blank?

    AssignmentClientOwnership.active
                             .includes(:user)
                             .find_by(account_id: inbox.account_id, contact_id: conversation.contact_id)&.user
  end

  def track_assignment(agent, conversation)
    return unless sticky_owner_enabled?
    return if conversation.contact_id.blank?

    ownership = AssignmentClientOwnership.find_or_initialize_by(
      account_id: inbox.account_id,
      contact_id: conversation.contact_id
    )
    ownership.assign_attributes(
      user: agent,
      assignment_policy: policy,
      last_assigned_at: Time.current,
      expires_at: sticky_owner_duration_days.days.from_now
    )
    ownership.save!
  end

  private

  def sticky_owner_enabled?
    policy&.sticky_owner_enabled?
  end

  def sticky_owner_duration_days
    policy&.sticky_owner_duration_days.to_i.positive? ? policy.sticky_owner_duration_days : 30
  end

  def agent_user(member)
    return member.user if member.respond_to?(:user)

    member
  end
end
