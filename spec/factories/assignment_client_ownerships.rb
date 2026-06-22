FactoryBot.define do
  factory :assignment_client_ownership do
    account
    contact
    user
    assignment_policy
    last_assigned_at { Time.current }
    expires_at { 30.days.from_now }
  end
end
