FactoryBot.define do
  factory :crm_task_status, class: 'Crm::TaskStatus' do
    account
    sequence(:name) { |n| "Task Status #{n}" }
    sequence(:code) { |n| "task_status_#{n}" }
    sequence(:position) { |n| n }
    category { 'open' }
    sequence(:color) { |n| Crm::TaskStatus::STANDARD_COLORS[(n - 1) % Crm::TaskStatus::STANDARD_COLORS.length] }
    active { true }
    default { false }
  end
end
