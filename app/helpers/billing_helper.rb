module BillingHelper
  private

  def default_plan?(account)
    installation_config = InstallationConfig.find_by(name: 'CHATWOOT_CLOUD_PLANS')
    default_plan = installation_config&.value&.first

    # Return false if not plans are configured, so that no checks are enforced
    return false if default_plan.blank?

    account.custom_attributes['plan_name'].nil? || account.custom_attributes['plan_name'] == default_plan['name']
  end

  def conversations_this_month(account)
    account.conversations.where('created_at > ?', 30.days.ago).count
  end

  def inboxes(account)
    account.text_channels_count
  end

  def call_inboxes(account)
    account.call_channels_count
  end

  def agents(account)
    account.countable_users_for_limits.count
  end
end
