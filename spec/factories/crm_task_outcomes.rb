FactoryBot.define do
  factory :crm_task_outcome, class: 'Crm::TaskOutcome' do
    account
    association :task_type, factory: :crm_task_type
    sequence(:name) { |index| "Outcome #{index}" }
    sequence(:code) { |index| "outcome_#{index}" }
    active { true }
    default { false }
    requires_note { false }

    after(:build) do |outcome|
      outcome.account = outcome.task_type.account
    end
  end
end
