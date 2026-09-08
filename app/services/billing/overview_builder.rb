class Billing::OverviewBuilder
  LIMIT_KEYS = %w[agents storage_bytes].freeze

  def initialize(account:, user: nil, at: Time.current)
    @account = account
    @user = user
    @at = at
  end

  def call
    {
      configured: workspace_link.present?,
      billing_access: billing_access_payload,
      billing_account: billing_account_payload,
      workspace: workspace_payload,
      subscription: subscription_payload,
      limits: limits_payload
    }
  end

  private

  attr_reader :account, :user, :at

  def workspace_link
    @workspace_link ||= BillingAccountWorkspace.active.find_by(account_id: account.id)
  end

  def billing_account
    workspace_link&.billing_account
  end

  def billing_membership
    @billing_membership ||= billing_account&.memberships&.active&.find_by(user_id: user&.id)
  end

  def subscription
    @subscription ||= billing_account&.current_subscription
  end

  def billing_account_payload
    return unless billing_account && billing_membership

    {
      id: billing_account.id,
      name: billing_account.name,
      status: billing_account.status,
      currency: billing_account.default_currency,
      workspace_count: billing_account.workspace_links.active.count,
      unique_user_count: unique_billing_user_count
    }
  end

  def workspace_payload
    { id: account.id, name: account.name }
  end

  def billing_access_payload
    { role: billing_membership&.role }
  end

  def subscription_payload
    return unless subscription

    {
      status: subscription.status,
      current_period_starts_at: subscription.current_period_starts_at,
      current_period_ends_at: subscription.current_period_ends_at,
      cancel_at_period_end: subscription.cancel_at_period_end,
      plan: subscription.plan_snapshot,
      price: billing_membership ? subscription.price_snapshot : nil
    }
  end

  def limits_payload
    LIMIT_KEYS.map do |key|
      resolved = resolver.resolve(key)
      {
        key: key,
        value: resolved.value,
        unlimited: resolved.unlimited,
        consumed: consumed_for(key),
        source: resolved.source
      }
    end
  end

  def resolver
    @resolver ||= Billing::EntitlementResolver.new(account: account, at: at)
  end

  def consumed_for(key)
    return account.countable_users_for_limits.count if key == 'agents'

    AccountLimits::StorageUsageService.new(account: account).usage_bytes
  end

  def unique_billing_user_count
    billing_account.workspace_links.active
                   .joins(account: :account_users)
                   .where.not(account_users: { user_id: SuperAdmin.select(:id) })
                   .distinct
                   .count('account_users.user_id')
  end
end
