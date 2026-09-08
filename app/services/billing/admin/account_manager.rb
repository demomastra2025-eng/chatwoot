class Billing::Admin::AccountManager
  STORAGE_GB_IN_BYTES = 1.gigabyte

  def initialize(billing_account:, actor:)
    @billing_account = billing_account
    @actor = actor
  end

  def attach_workspace!(account_id)
    BillingAccount.transaction do
      account = Account.lock.find(account_id)
      billing_account.with_lock do
        active_link = BillingAccountWorkspace.active.find_by(account: account)
        if active_link && active_link.billing_account != billing_account
          raise ArgumentError, 'Workspace is already attached to another billing organization'
        end

        link = billing_account.workspace_links.find_or_initialize_by(account: account)
        link.update!(status: 'active', detached_at: nil)
        audit!('workspace_attached', account_id: account.id, link_id: link.id)
        link
      end
    end
  rescue ActiveRecord::RecordNotUnique
    raise ArgumentError, 'Workspace is already attached to another billing organization'
  end

  def update_account!(attributes)
    mutate do
      previous = billing_account.billing_details
      billing_account.update!(attributes)
      audit!(
        'billing_account_updated',
        before: previous,
        after: billing_account.billing_details
      )
      billing_account
    end
  end

  def detach_workspace!(link_id)
    mutate do
      link = billing_account.workspace_links.active.find(link_id)
      link.update!(status: 'detached', detached_at: Time.current)
      audit!('workspace_detached', account_id: link.account_id, link_id: link.id)
      link
    end
  end

  def upsert_membership!(user_id:, role:)
    mutate do
      user = User.find(user_id)
      role = role.to_s
      raise ArgumentError, 'invalid billing role' unless role.in?(BillingAccountMembership::ROLES)

      deactivate_current_owner! if role == 'owner'
      membership = billing_account.memberships.find_or_initialize_by(user: user)
      prevent_owner_demotion!(membership, role)
      membership.update!(role: role, status: 'active')
      audit!('membership_upserted', user_id: user.id, membership_id: membership.id, role: role)
      membership
    end
  end

  def deactivate_membership!(membership_id)
    mutate do
      membership = billing_account.memberships.active.find(membership_id)
      raise ArgumentError, 'active billing owner cannot be deactivated' if membership.owner?

      membership.update!(status: 'inactive')
      audit!('membership_deactivated', user_id: membership.user_id, membership_id: membership.id)
      membership
    end
  end

  def assign_subscription!(plan_id:, price_id:, status:, period_starts_at:, period_ends_at:)
    mutate do
      plan = BillingPlan.active.find(plan_id)
      price = price_id.present? ? plan.prices.find(price_id) : nil
      status = status.to_s
      raise ArgumentError, 'invalid subscription status' unless status.in?(BillingSubscription::STATUSES)

      subscription = replace_or_update_subscription!(plan, price, status, period_starts_at, period_ends_at)
      audit!(
        'subscription_assigned', subscription_id: subscription.id, plan_id: plan.id,
                                 price_id: price&.id, status: status
      )
      subscription
    end
  end

  def update_allocation!(account_id:, agents:, storage_gb:)
    mutate do
      subscription = billing_account.subscriptions.entitling.order(created_at: :desc).first!
      account = billing_account.workspaces.find(account_id)
      allocation = subscription.entitlement_allocations.find_or_initialize_by(account: account)
      limits = allocation_limits(allocation, agents, storage_gb)
      allocation.update!(limits: limits)
      audit!('allocation_updated', subscription_id: subscription.id, allocation_id: allocation.id,
                                   account_id: account.id, limits: limits)
      allocation
    end
  end

  def audit!(action, details = {})
    billing_account.audit_events.create!(super_admin: actor, action: action, details: details)
  end

  private

  attr_reader :billing_account, :actor

  def mutate(&)
    BillingAccount.transaction { billing_account.with_lock(&) }
  end

  def deactivate_current_owner!
    billing_account.memberships.active.owner.find_each do |membership|
      membership.update!(status: 'inactive')
    end
  end

  def prevent_owner_demotion!(membership, new_role)
    return unless membership.persisted? && membership.owner? && membership.active? && new_role != 'owner'

    raise ArgumentError, 'assign another owner before changing the current owner role'
  end

  def replace_or_update_subscription!(plan, price, status, period_starts_at, period_ends_at)
    current = billing_account.subscriptions.entitling.order(created_at: :desc).first ||
              billing_account.subscriptions.order(created_at: :desc).first
    same_catalog = current&.billing_plan == plan && current&.billing_plan_price == price
    attributes = {
      status: status,
      current_period_starts_at: parse_time(period_starts_at),
      current_period_ends_at: parse_time(period_ends_at)
    }

    if same_catalog && (current.status != 'canceled' || status == 'canceled')
      current.update!(attributes)
      return current
    end

    current&.update!(status: 'canceled')
    billing_account.subscriptions.create!(attributes.merge(billing_plan: plan, billing_plan_price: price))
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  end

  def allocation_limits(allocation, agents, storage_gb)
    limits = allocation.limits.deep_dup
    assign_limit!(limits, 'agents', agents) { |value| Integer(value.to_s, 10) }
    assign_limit!(limits, 'storage_bytes', storage_gb) do |value|
      (BigDecimal(value.to_s) * STORAGE_GB_IN_BYTES).round(0).to_i
    end
    limits
  end

  def assign_limit!(limits, key, raw_value)
    if raw_value.blank?
      limits.delete(key)
      return
    end

    value = yield(raw_value)
    raise ArgumentError, "#{key} cannot be negative" if value.negative?

    limits[key] = value
  end
end
