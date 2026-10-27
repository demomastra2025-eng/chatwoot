module Enterprise::Inbox
  def member_ids_with_assignment_capacity
    return super unless enable_auto_assignment?
    return filter_by_capacity(available_agents).map(&:user_id) - excluded_policy_user_ids if auto_assignment_v2_enabled?

    max_assignment_limit = auto_assignment_config['max_assignment_limit']
    overloaded_agent_ids = max_assignment_limit.present? ? get_agent_ids_over_assignment_limit(max_assignment_limit) : []
    super - overloaded_agent_ids - excluded_policy_user_ids
  end

  def active_bot?
    super || captain_active?
  end

  # The AI may answer in this channel by itself now: the channel is switched on (text) or its number has an enabled agent (voice),
  # at least one external agent is enabled, and the workspace has quota left (see Captain::ChannelScope#runtime_enabled?).
  def captain_active?
    captain_usage_available? && Captain::ChannelScope.for_inbox(self).runtime_enabled?
  end

  def captain_auto_reply_allowed?
    captain_inbox&.auto_reply_allowed_now? || false
  end

  private

  def captain_usage_available?
    account.captain_quota_available?
  end

  def get_agent_ids_over_assignment_limit(limit)
    conversations
      .open
      .where(account_id: account_id)
      .select(:assignee_id)
      .group(:assignee_id)
      .having("count(*) >= #{limit.to_i}")
      .filter_map(&:assignee_id)
  end

  def ensure_valid_max_assignment_limit
    return if auto_assignment_config['max_assignment_limit'].blank?
    return if auto_assignment_config['max_assignment_limit'].to_i.positive?

    errors.add(:auto_assignment_config, 'max_assignment_limit must be greater than 0')
  end
end
