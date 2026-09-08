FactoryBot.define do
  factory :crm_task, class: 'Crm::Task' do
    account
    title { 'Follow up with client' }
    activity_type { 'task' }
    priority { 'medium' }

    after(:build) do |task|
      task.status ||= create(:crm_task_status, account: task.account)
      task.task_type ||=
        task.account.crm_task_types.find_by(code: task.activity_type) ||
        create(:crm_task_type, account: task.account, code: task.activity_type)
    end
  end
end
