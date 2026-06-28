require 'rails_helper'

RSpec.describe Captain::Tools::UpdateTaskTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('crm_tasks')
  end

  it 'returns normalized update_task payload' do
    conversation = create(:conversation, account: account)
    status = create(:crm_task_status, account: account)
    task = create(:crm_task, account: account, title: 'Old task', status: status, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, task: { id: task.id } })

    payload = JSON.parse(
      tool.perform(
        tool_context,
        title: 'New task',
        activity_type: 'call',
        outcome: 'not_done',
        outcome_note: 'Client was unavailable; retry tomorrow'
      )
    )

    expect(payload).to include(
      'action' => 'update_task',
      'activity_type' => 'call',
      'outcome' => 'not_done',
      'outcome_note' => 'Client was unavailable; retry tomorrow',
      'task_id' => task.id,
      'status_id' => status.id
    )
    expect(payload['task']).to include(
      'activity_type' => 'call',
      'id' => task.id,
      'outcome' => 'not_done',
      'outcome_note' => 'Client was unavailable; retry tomorrow',
      'title' => 'New task'
    )
  end
end
