module Enterprise::Inbox
  def member_ids_with_assignment_capacity
    return super unless enable_auto_assignment?
    return filter_by_capacity(available_agents).map(&:user_id) if auto_assignment_v2_enabled?

    max_assignment_limit = auto_assignment_config['max_assignment_limit']
    overloaded_agent_ids = max_assignment_limit.present? ? get_agent_ids_over_assignment_limit(max_assignment_limit) : []
    super - overloaded_agent_ids
  end

  def active_bot?
    super || captain_active?
  end

  def captain_active?
    return false unless captain_assistant&.active? && captain_usage_available?
    return true if channel_type == 'Channel::Voice'

    text_captain_active?
  end

  def captain_auto_reply_allowed?
    captain_inbox&.auto_reply_allowed_now? || false
  end

  private

  def text_captain_active?
    captain_inbox&.ai_enabled? && account.captain_ai_enabled? &&
      account.captain_default_assistant_id.to_i == captain_inbox.captain_assistant_id
  end

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
