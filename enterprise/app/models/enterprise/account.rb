module Enterprise::Account
  LIMIT_COUNTER_EXCLUDED_USER_IDS_KEY = 'limit_counter_excluded_user_ids'.freeze

  # TODO: Remove this when we upgrade administrate gem to the latest version
  # this is a temporary method since current administrate doesn't support virtual attributes
  def manually_managed_features; end

  def limit_counter_excluded_user_ids
    normalize_limit_counter_excluded_user_ids(
      (custom_attributes || {})[LIMIT_COUNTER_EXCLUDED_USER_IDS_KEY]
    )
  end

  def limit_counter_excluded_user_ids=(value)
    updated_custom_attributes = (custom_attributes || {}).dup
    normalized_ids = normalize_limit_counter_excluded_user_ids(value)

    if normalized_ids.present?
      updated_custom_attributes[LIMIT_COUNTER_EXCLUDED_USER_IDS_KEY] = normalized_ids
    else
      updated_custom_attributes.delete(LIMIT_COUNTER_EXCLUDED_USER_IDS_KEY)
    end

    self.custom_attributes = updated_custom_attributes
  end

  def limit_counter_excluded_user_ids_raw
    limit_counter_excluded_user_ids.join(', ')
  end

  def countable_users_for_limits
    excluded_ids = limit_counter_excluded_user_ids
    return users unless excluded_ids.present?

    users.where.not(id: excluded_ids)
  end

  def billing_limits_overview
    usage_overview = account_usage_overview

    {
      agents: usage_overview[:agents],
      inboxes: usage_overview[:inboxes],
      conversation: usage_overview[:conversations],
      non_web_inboxes: usage_overview[:non_web_inboxes],
      storage: usage_overview[:storage],
      captain: usage_overview[:captain]
    }.with_indifferent_access
  end

  def account_usage_overview
    {
      agents: agent_usage_summary(consumed: countable_users_for_limits.count),
      inboxes: usage_limit_summary(:inboxes, consumed: inboxes.count),
      conversations: usage_limit_summary(:conversations, consumed: conversations_this_month_count),
      non_web_inboxes: usage_limit_summary(:non_web_inboxes, consumed: main_channels_count),
      emails: email_usage_summary(consumed: emails_sent_today),
      storage: usage_limits[:storage],
      captain: usage_limits[:captain]
    }.with_indifferent_access
  end

  # Auto-sync advanced_assignment with assignment_v2 when features are bulk-updated via admin UI
  def selected_feature_flags=(features)
    super
    sync_assignment_features
  end

  def mark_for_deletion(reason = 'manual_deletion')
    reason = reason.to_s == 'manual_deletion' ? 'manual_deletion' : 'inactivity'

    result = custom_attributes.merge!(
      'marked_for_deletion_at' => 7.days.from_now.iso8601,
      'marked_for_deletion_reason' => reason
    ) && save

    # Send notification to admin users if the account was successfully marked for deletion
    if result
      mailer = AdministratorNotifications::AccountNotificationMailer.with(account: self)
      if reason == 'manual_deletion'
        mailer.account_deletion_user_initiated(self, reason).deliver_later
      else
        mailer.account_deletion_for_inactivity(self, reason).deliver_later
      end
    end

    result
  end

  def unmark_for_deletion
    custom_attributes.delete('marked_for_deletion_at') && custom_attributes.delete('marked_for_deletion_reason') && save
  end

  private

  def sync_assignment_features
    if feature_enabled?('assignment_v2')
      # Enable advanced_assignment for Business/Enterprise plans
      send('feature_advanced_assignment=', true) if business_or_enterprise_plan?
    else
      # Disable advanced_assignment when assignment_v2 is disabled
      send('feature_advanced_assignment=', false)
    end
  end

  def business_or_enterprise_plan?
    plan_name = custom_attributes['plan_name']
    %w[Business Enterprise].include?(plan_name)
  end

  def normalize_limit_counter_excluded_user_ids(value)
    raw_values = value.is_a?(String) ? value.split(/[,\s]+/) : value

    Array(raw_values)
      .filter_map do |candidate|
        Integer(candidate.to_s.strip, 10)
      rescue ArgumentError, TypeError
        nil
      end
      .select(&:positive?)
      .uniq
      .sort
  end
end
