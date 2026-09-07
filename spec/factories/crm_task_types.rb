FactoryBot.define do
  factory :crm_task_type, class: 'Crm::TaskType' do
    account
    sequence(:name) { |index| "Task type #{index}" }
    sequence(:code) { |index| "task_type_#{index}" }
    icon { 'i-lucide-list-todo' }
    active { true }
    default { false }
  end
end
