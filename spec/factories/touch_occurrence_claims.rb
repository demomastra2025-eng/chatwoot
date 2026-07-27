FactoryBot.define do
  factory :touch_occurrence_claim do
    account { create(:account) }
    touch_plan_enrollment { create(:touch_plan_enrollment, account: account) }
    sequence(:step_key) { |n| "step-#{n}" }
    sequence(:occurrence_key) { |n| "occurrence-#{n}" }
    due_at { Time.current }
    status { 'claimed' }
    claimed_at { Time.current }
    metadata { {} }
  end
end
