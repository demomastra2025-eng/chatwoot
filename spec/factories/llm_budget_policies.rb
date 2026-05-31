FactoryBot.define do
  factory :llm_budget_policy do
    account
    scope_type { 'account' }
    add_attribute(:feature) { nil }
    active { true }
    hard_stop { true }
    daily_budget { 1.0 }
    monthly_budget { 10.0 }
    warning_threshold { 0.8 }
    fallback_profile { 'low_cost' }
    per_feature_caps { {} }
    metadata { {} }
  end
end
