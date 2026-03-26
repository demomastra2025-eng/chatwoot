FactoryBot.define do
  factory :crm_task, class: 'Crm::Task' do
    account
    title { 'Follow up with client' }
    priority { 'medium' }

    after(:build) do |task|
      task.status ||= create(:crm_task_status, account: task.account)
    end
  end
end
