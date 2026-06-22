FactoryBot.define do
  factory :assignment_policy do
    account
    sequence(:name) { |n| "Assignment Policy #{n}" }
    description { 'Test assignment policy description' }
    assignment_order { 0 }
    conversation_priority { 0 }
    fair_distribution_limit { 10 }
    fair_distribution_window { 3600 }
    assignment_delay_minutes { 0 }
    exclusion_rules { {} }
    max_open_conversations { nil }
    monthly_new_client_quota { nil }
    sticky_owner_enabled { false }
    sticky_owner_duration_days { 30 }
    enabled { true }
  end
end
