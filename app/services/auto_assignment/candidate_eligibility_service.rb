# frozen_string_literal: true

class AutoAssignment::CandidateEligibilityService
  Result = Struct.new(:agents, :candidate_summaries, keyword_init: true)

  pattr_initialize [:inbox!, :conversation!, :agents!, :policy]

  def perform
    eligible_agents = []
    candidate_summaries = []

    agents.each do |member|
      user = agent_user(member)
      next unless user

      reasons = rejection_reasons_for(user)

      if reasons.empty?
        eligible_agents << member
      else
        candidate_summaries << {
          user_id: user.id,
          name: user.name,
          reasons: reasons
        }
      end
    end

    Result.new(agents: eligible_agents, candidate_summaries: candidate_summaries)
  end

  private

  def rejection_reasons_for(user)
    reasons = []
    reasons << 'max_open_conversations_reached' unless within_open_conversation_limit?(user)
    reasons << 'monthly_new_client_quota_reached' unless quota_service.within_monthly_quota?(user, conversation)
    reasons
  end

  def within_open_conversation_limit?(user)
    limit = policy&.max_open_conversations.to_i
    return true unless limit.positive?

    active_conversations_scope.where(assignee_id: user.id).count < limit
  end

  def active_conversations_scope
    scope = inbox.conversations.open
    return scope unless policy&.assign_pending_conversations?

    scope.or(inbox.conversations.pending)
  end

  def quota_service
    @quota_service ||= AutoAssignment::QuotaService.new(inbox: inbox, policy: policy)
  end

  def agent_user(member)
    return member.user if member.respond_to?(:user)

    member
  end
end
