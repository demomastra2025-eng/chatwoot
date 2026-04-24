require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ChangeTaskStatusService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  before do
    account.enable_features!('crm_tasks')
  end

  it 'returns normalized task status transition payload wrapper' do
    old_status = create(:crm_task_status, account: account, name: 'Todo', code: 'todo')
    new_status = create(:crm_task_status, account: account, name: 'Done', code: 'done')
    task = create(:crm_task, account: account, status: old_status, originating_conversation_id: conversation.id)

    payload = JSON.parse(service.execute(status_code: 'done'))

    expect(payload).to include('action' => 'change_task_status')
    expect(payload['task']).to include(
      'id' => task.id,
      'status_id' => new_status.id
    )
  end
end
