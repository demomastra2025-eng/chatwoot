require 'rails_helper'

RSpec.describe Captain::Tools::ChangeTaskStatusTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('crm_tasks')
  end

  it 'returns normalized change_task_status payload' do
    old_status = create(:crm_task_status, account: account, code: 'todo')
    new_status = create(:crm_task_status, account: account, code: 'done')
    conversation = create(:conversation, account: account)
    task = create(:crm_task, account: account, status: old_status, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, task: { id: task.id } })

    payload = JSON.parse(tool.perform(tool_context, status_code: 'done'))

    expect(payload).to include('action' => 'change_task_status', 'task_id' => task.id, 'status_id' => new_status.id)
    expect(payload['task']).to include('id' => task.id, 'status_id' => new_status.id)
  end

  it 'returns validation error for zero status ID placeholders' do
    old_status = create(:crm_task_status, account: account, code: 'todo')
    conversation = create(:conversation, account: account)
    task = create(:crm_task, account: account, status: old_status, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, task: { id: task.id } })

    result = tool.perform(tool_context, status_id: 0)

    expect(result).to include('ERROR: ArgumentError: One of status_id, status_name, or status_code is required')
    expect(result).not_to include('ActiveRecord::RecordNotFound')
    expect(task.reload.status_id).to eq(old_status.id)
  end
end
