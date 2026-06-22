# frozen_string_literal: true

module Enterprise::AutoAssignment::AssignmentService
  private

  # Override assignment config to use policy if available
  def assignment_config
    return super unless policy

    {
      'conversation_priority' => policy.conversation_priority,
      'fair_distribution_limit' => policy.fair_distribution_limit,
      'fair_distribution_window' => policy.fair_distribution_window,
      'balanced' => policy.balanced?
    }.compact
  end

  # Extend agent finding to add capacity checks and keep core policy gates.
  def find_available_agent(conversation = nil)
    reset_candidate_summaries

    agents = filter_agents_by_team(inbox.available_agents, conversation)
    return nil if agents.nil?

    agents = filter_agents_by_rate_limit(agents)
    agents = filter_agents_by_capacity(agents) if capacity_filtering_enabled?
    agents = filter_agents_by_policy_limits(agents, conversation)
    return nil if agents.empty?

    sticky_owner = sticky_owner_service.available_owner_for(conversation, agents)
    return sticky_owner if sticky_owner

    assignment_selector.select_agent(agents)
  end

  def assignment_selector
    return round_robin_selector unless policy&.balanced?
    return round_robin_selector unless account.feature_enabled?('advanced_assignment')

    balanced_selector
  end

  def filter_agents_by_capacity(agents)
    return agents unless capacity_filtering_enabled?

    capacity_service = Enterprise::AutoAssignment::CapacityService.new
    agents.select do |agent_member|
      has_capacity = capacity_service.agent_has_capacity?(agent_member.user, inbox)
      add_candidate_summary(agent_member.user, ['agent_capacity_policy_limit_reached']) unless has_capacity
      has_capacity
    end
  end

  def capacity_filtering_enabled?
    account.feature_enabled?('advanced_assignment') &&
      account.account_users.joins(:agent_capacity_policy).exists?
  end

  def round_robin_selector
    @round_robin_selector ||= AutoAssignment::RoundRobinSelector.new(inbox: inbox)
  end

  def balanced_selector
    @balanced_selector ||= Enterprise::AutoAssignment::BalancedSelector.new(inbox: inbox)
  end

  def policy
    @policy ||= inbox.assignment_policy
  end

  def account
    inbox.account
  end

  # Override to apply exclusion rules
  def unassigned_conversations(limit)
    scope = inbox.conversations.unassigned.open

    # Apply exclusion rules from capacity policy or assignment policy
    scope = apply_exclusion_rules(scope)
    scope = apply_assignment_delay(scope)
    scope = apply_conversation_priority(scope)

    scope.limit(limit)
  end

  def apply_exclusion_rules(scope)
    capacity_policy = inbox.inbox_capacity_limits.first&.agent_capacity_policy
    return scope unless capacity_policy

    exclusion_rules = capacity_policy.exclusion_rules || {}
    scope = apply_label_exclusions(scope, exclusion_rules['excluded_labels'])
    apply_age_exclusions(scope, exclusion_rules['exclude_older_than_hours'])
  end

  def apply_label_exclusions(scope, excluded_labels)
    return scope if excluded_labels.blank?

    scope.tagged_with(excluded_labels, exclude: true, on: :labels)
  end

  def apply_age_exclusions(scope, hours_threshold)
    return scope if hours_threshold.blank?

    hours = hours_threshold.to_i
    return scope unless hours.positive?

    scope.where('conversations.created_at >= ?', hours.hours.ago)
  end
end
