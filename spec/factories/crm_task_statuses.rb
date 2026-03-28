FactoryBot.define do
  factory :crm_task_status, class: 'Crm::TaskStatus' do
    account
    sequence(:name) { |n| "Task Status #{n}" }
    sequence(:code) { |n| "task_status_#{n}" }
    sequence(:position) { |n| n }
    category { 'open' }
    color { Crm::TaskStatus::STANDARD_COLORS.first }
    active { true }
    default { false }
  end
end
