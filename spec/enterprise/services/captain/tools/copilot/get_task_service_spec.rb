require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetTaskService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('crm_tasks')
  end

  it 'returns a normalized task payload' do
    status = create(:crm_task_status, account: account, name: 'Todo')
    task = create(:crm_task, account: account, title: 'Call client', description: 'Follow up', status: status)

    payload = JSON.parse(service.execute(task_id: task.id))

    expect(payload['task']).to include(
      'id' => task.id,
      'title' => 'Call client',
      'description' => 'Follow up',
      'status_id' => status.id
    )
  end

  it 'returns a structured failure when the task is missing' do
    expect(service.execute(task_id: 999)).to eq('ERROR: Task not found')
  end
end
