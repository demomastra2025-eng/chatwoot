FactoryBot.define do
  factory :account_user_lifecycle_snapshot do
    account
    user
    role { 'agent' }
    availability { 'offline' }
    team_ids { [] }
    inbox_ids { [] }
    deactivated_at { Time.current }
  end
end
