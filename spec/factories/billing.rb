FactoryBot.define do
  factory :billing_account do
    sequence(:name) { |number| "Billing account #{number}" }
    status { 'active' }
    default_currency { 'KZT' }
    default_locale { 'ru' }
  end

  factory :billing_account_membership do
    billing_account
    user
    role { 'viewer' }
    status { 'active' }
  end

  factory :billing_account_workspace do
    billing_account
    account
    status { 'active' }
  end

  factory :billing_plan do
    sequence(:code) { |number| "plan-#{number}" }
    sequence(:name) { |number| "Plan #{number}" }
    version { 1 }
    status { 'active' }
    entitlements { { 'limits' => { 'agents' => 5, 'storage_bytes' => 10.gigabytes } } }
  end

  factory :billing_plan_price do
    billing_plan
    currency { 'KZT' }
    amount_cents { 10_000_00 }
    interval { 'month' }
    interval_count { 1 }
  end

  factory :billing_subscription do
    billing_account
    billing_plan
    billing_plan_price { association :billing_plan_price, billing_plan: billing_plan }
    status { 'active' }
    current_period_starts_at { Time.current }
    current_period_ends_at { 1.month.from_now }
  end

  factory :billing_entitlement_allocation do
    billing_subscription
    account
    limits { { 'agents' => 5, 'storage_bytes' => 10.gigabytes } }
  end
end
