# frozen_string_literal: true

class AutoAssignment::AssignmentService
  pattr_initialize [:inbox!]

  def perform_bulk_assignment(limit: 100)
    return 0 unless bulk_assignment_enabled?

    unassigned_conversations(limit).count { |conversation| perform_for_conversation(conversation) }
  end

  private

  def bulk_assignment_enabled?
    inbox.auto_assignment_v2_enabled? &&
      inbox.enable_auto_assignment? &&
      active_policy_enabled? &&
      inbox.available_agents.exists?
  end

  def active_policy_enabled? = active_policy.blank? || active_policy.enabled?

  def perform_for_conversation(conversation)
    unless assignable?(conversation)
      decision_logger.skipped(conversation: conversation, reasons: ['conversation_not_assignable'])
      return false
    end

    agent = find_available_agent(conversation)
    unless agent
      decision_logger.skipped(
        conversation: conversation,
        reasons: ['no_eligible_agents'],
        candidate_summaries: candidate_summaries
      )
      return false
    end

    assign_conversation(conversation, agent)
  end

  def assignable?(conversation) = conversation.status == 'open' && conversation.assignee_id.nil?

  def unassigned_conversations(limit)
    scope = inbox.conversations.unassigned.open
    scope = apply_assignment_delay(scope)
    scope = apply_conversation_priority(scope)
    scope.limit(limit)
  end

  def apply_assignment_delay(scope)
    delay_minutes = active_policy&.assignment_delay_minutes.to_i
    return scope unless delay_minutes.positive?

    scope.where('conversations.created_at <= ?', delay_minutes.minutes.ago)
  end

  def apply_conversation_priority(scope)
    if active_policy&.longest_waiting?
      scope.reorder(last_activity_at: :asc, created_at: :asc)
    else
      scope.reorder(created_at: :asc)
    end
  end

  def find_available_agent(conversation = nil)
    reset_candidate_summaries

    agents = filter_agents_by_team(inbox.available_agents, conversation)
    return nil if agents.nil?

    agents = filter_agents_by_rate_limit(agents)
    agents = filter_agents_by_policy_limits(agents, conversation)
    return nil if agents.empty?

    sticky_owner = sticky_owner_service.available_owner_for(conversation, agents)
    return sticky_owner if sticky_owner

    round_robin_selector.select_agent(agents)
  end

  def filter_agents_by_team(agents, conversation)
    return agents if conversation&.team_id.blank?

    team = conversation.team
    if team.blank? || team.allow_auto_assign.blank?
      add_candidate_summary(nil, ['team_auto_assignment_disabled'])
      return nil
    end

    team_member_ids = team.members.ids
    filtered_agents = agents.where(user_id: team_member_ids)
    add_candidate_summary(nil, ['no_available_team_members']) if filtered_agents.empty?
    filtered_agents
  end

  def filter_agents_by_rate_limit(agents)
    agents.select do |agent_member|
      rate_limiter = build_rate_limiter(agent_member.user)
      within_limit = rate_limiter.within_limit?
      add_candidate_summary(agent_member.user, ['fair_distribution_limit_reached']) unless within_limit
      within_limit
    end
  end

  def filter_agents_by_policy_limits(agents, conversation)
    result = AutoAssignment::CandidateEligibilityService.new(
      inbox: inbox,
      conversation: conversation,
      agents: agents,
      policy: active_policy
    ).perform
    @candidate_summaries.concat(result.candidate_summaries)
    result.agents
  end

  def assign_conversation(conversation, agent)
    unless claim_and_assign(conversation, agent)
      record_failed_assignment(conversation, agent)
      return false
    end

    conversation.reload

    rate_limiter = build_rate_limiter(agent)
    rate_limiter.track_assignment(conversation)
    quota_service.track_assignment(agent, conversation)
    sticky_owner_service.track_assignment(agent, conversation)
    record_successful_assignment(conversation, agent)

    dispatch_assignment_event(conversation, agent)
    true
  end

  # Atomically claim the conversation row so overlapping bulk runs cannot both
  # assign the same unassigned conversation when an in-flight job gate expires.
  def claim_and_assign(conversation, agent)
    Current.executed_by = active_policy || inbox

    Conversation.transaction do
      locked_conversation = inbox.conversations
                                 .open
                                 .where(id: conversation.id, assignee_id: nil)
                                 .lock('FOR UPDATE SKIP LOCKED')
                                 .first
      next false unless locked_conversation

      locked_conversation.update!(assignee: agent)
      true
    end
  ensure
    Current.executed_by = nil
  end

  def dispatch_assignment_event(conversation, agent)
    Rails.configuration.dispatcher.dispatch(
      Events::Types::ASSIGNEE_CHANGED,
      Time.zone.now,
      conversation: conversation,
      user: agent
    )
  end

  def record_failed_assignment(conversation, agent)
    decision_logger.failed(
      conversation: conversation,
      reasons: ['conversation_claim_failed'],
      candidate_summaries: candidate_summaries,
      metadata: assignment_metadata(agent)
    )
  end

  def record_successful_assignment(conversation, agent)
    decision_logger.assigned(
      conversation: conversation,
      assigned_user: agent,
      reasons: ['assigned'],
      candidate_summaries: candidate_summaries,
      metadata: assignment_metadata(agent)
    )
  end

  def assignment_metadata(agent)
    {
      strategy: active_policy&.assignment_order || 'round_robin',
      assignment_delay_minutes: active_policy&.assignment_delay_minutes.to_i,
      max_open_conversations: active_policy&.max_open_conversations,
      monthly_new_client_quota: active_policy&.monthly_new_client_quota,
      sticky_owner_enabled: active_policy&.sticky_owner_enabled?,
      assigned_user_id: agent.id
    }.compact
  end

  def active_policy = @active_policy ||= inbox.assignment_policy

  def quota_service = @quota_service ||= AutoAssignment::QuotaService.new(inbox: inbox, policy: active_policy)

  def sticky_owner_service = @sticky_owner_service ||= AutoAssignment::StickyOwnerService.new(inbox: inbox, policy: active_policy)

  def decision_logger = @decision_logger ||= AutoAssignment::DecisionLogger.new(inbox: inbox, policy: active_policy)

  def build_rate_limiter(agent)
    AutoAssignment::RateLimiter.new(inbox: inbox, agent: agent)
  end

  def round_robin_selector = @round_robin_selector ||= AutoAssignment::RoundRobinSelector.new(inbox: inbox)

  def reset_candidate_summaries
    @candidate_summaries = []
  end

  def candidate_summaries = @candidate_summaries ||= []

  def add_candidate_summary(user, reasons)
    candidate_summaries << {
      user_id: user&.id,
      name: user&.name,
      reasons: reasons
    }
  end
end

AutoAssignment::AssignmentService.prepend_mod_with('AutoAssignment::AssignmentService')
