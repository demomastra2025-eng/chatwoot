FactoryBot.define do
  factory :assignment_quota_usage do
    account
    user
    contact
    conversation
    assignment_policy
    period_start { Time.zone.today.beginning_of_month }
    period_end { Time.zone.today.end_of_month }
  end
end
