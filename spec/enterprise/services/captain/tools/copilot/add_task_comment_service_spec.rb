require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::AddTaskCommentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  before do
    account.enable_features!('crm_tasks')
  end

  it 'returns a normalized task comment payload' do
    status = create(:crm_task_status, account: account)
    task = create(:crm_task, account: account, status: status, originating_conversation_id: conversation.id)

    payload = JSON.parse(service.execute(body: 'Task follow-up'))

    expect(payload).to include(
      'action' => 'add_task_comment',
      'task_id' => task.id
    )
    expect(payload.fetch('comment')).to include('body' => 'Task follow-up', 'user_id' => user.id)
  end
end
