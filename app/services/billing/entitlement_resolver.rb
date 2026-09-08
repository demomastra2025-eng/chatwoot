class Billing::EntitlementResolver
  Result = Data.define(:value, :unlimited, :source)

  def initialize(account:, at: Time.current, legacy_metadata: nil)
    @account = account
    @at = at
    @legacy_metadata = legacy_metadata
  end

  def resolve(limit_name)
    key = limit_name.to_s
    allocation = current_allocation

    return allocated_result(allocation, key) if allocation&.limits&.key?(key)

    metadata = legacy_limit_metadata(key)
    Result.new(value: metadata[:value], unlimited: metadata[:unlimited], source: :legacy)
  end

  private

  attr_reader :account, :at, :legacy_metadata

  def allocated_result(allocation, key)
    Result.new(value: allocation.limits.fetch(key), unlimited: false, source: :billing_allocation)
  end

  def current_allocation
    return @current_allocation if defined?(@current_allocation)

    allocations = current_subscription&.entitlement_allocations&.where(account_id: account.id)
    @current_allocation = allocations&.where('starts_at IS NULL OR starts_at <= ?', at)
                                     &.where('ends_at IS NULL OR ends_at > ?', at)
                                     &.first
  end

  def current_subscription
    return @current_subscription if defined?(@current_subscription)

    billing_account = BillingAccountWorkspace.active.find_by(account_id: account.id)&.billing_account
    @current_subscription = billing_account&.subscriptions&.entitling&.first
  end

  def legacy_limit_metadata(key)
    metadata = legacy_metadata&.call(key)
    return metadata.with_indifferent_access if metadata

    account_limit_metadata(key)
  end

  def account_limit_metadata(key)
    return account.agent_limit_metadata if key == 'agents' && account.respond_to?(:agent_limit_metadata)
    return account.usage_limit_metadata(key) if account.respond_to?(:usage_limit_metadata)

    value = account.usage_limits.with_indifferent_access[key]
    return { value: value, unlimited: false }.with_indifferent_access if value.present?

    { value: ChatwootApp.max_limit.to_i, unlimited: true }.with_indifferent_access
  end
end
