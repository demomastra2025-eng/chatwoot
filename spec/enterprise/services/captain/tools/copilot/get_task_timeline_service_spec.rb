require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetTaskTimelineService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('crm_tasks')
  end

  it 'returns a normalized task timeline payload' do
    status = create(:crm_task_status, account: account)
    task = create(:crm_task, account: account, status: status)
    comment = create(:crm_comment, account: account, commentable: task, user: user, body: 'Task note')

    payload = JSON.parse(service.execute(task_id: task.id, limit: 5))

    expect(payload).to include('task_id' => task.id)
    expect(payload.fetch('meta')).to include('count' => 1)
    expect(payload.fetch('items').first).to include(
      'item_type' => 'comment',
      'payload' => include('id' => comment.id, 'body' => 'Task note')
    )
  end

  it 'returns a structured failure when the task is missing' do
    expect(service.execute(task_id: 999)).to eq('ERROR: Task not found')
  end
end
