FactoryBot.define do
  factory :assignment_decision_log do
    account
    inbox
    conversation
    assignment_policy
    assigned_user { nil }
    outcome { :assigned }
    reasons { [] }
    candidate_summaries { [] }
    decision_metadata { {} }
  end
end
